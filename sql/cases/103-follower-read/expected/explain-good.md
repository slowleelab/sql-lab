# EXPLAIN 参考结果 - good.sql（Follower Read 读写分离）

## TiDB v7.5.1（20 万行，3+ TiKV 节点集群）

---

### 1. 启用 Follower Read

```sql
SET SESSION tidb_replica_read = 'follower';
SHOW VARIABLES LIKE 'tidb_replica_read';
```

```
+--------------------+----------+
| Variable_name      | Value    |
+--------------------+----------+
| tidb_replica_read  | follower |
+--------------------+----------+
```

---

### 2. Follower Read 下的聚合查询 EXPLAIN

```sql
EXPLAIN SELECT city, COUNT(*) AS cnt, AVG(score) AS avg_score
FROM t_follower
GROUP BY city;
```

```
+---------------------------+----------+-----------+-----------------+----------------------------------------------+
| id                        | estRows  | task      | access object   | operator info                                |
+---------------------------+----------+-----------+-----------------+----------------------------------------------+
| Projection_7              | 10.00    | root      |                 | t_follower.city, Column#5, Column#6           |
| └─HashAgg_9               | 10.00    | root      |                 | group by:t_follower.city, funcs:count(...),...|
|   └─TableReader_10        | 200000.00| root      |                 | data:TableFullScan_8                         |
|     └─TableFullScan_8     | 200000.00| cop[tikv] | table:t_follower| keep order:false                             |
+---------------------------+----------+-----------+-----------------+----------------------------------------------+
```

EXPLAIN 输出格式与 Leader Read 一致，区别在于 **coprocessor 请求的实际路由目标**：
- `tidb_replica_read = 'leader'`：请求发往各 Region 的 Leader
- `tidb_replica_read = 'follower'`：请求发往各 Region 的 Follower

> 路由差异无法在 EXPLAIN 文本中直接体现，需要通过 Grafana / TiDB Dashboard 观察各 TiKV 节点的请求分布。

---

### 3. Follower Read 配置项详解

#### `tidb_replica_read` 可选值

| 值 | 行为 | 适用场景 |
|----|------|---------|
| `leader`（默认） | 所有读请求只发给 Leader peer | 强一致性读，不能容忍任何延迟 |
| `follower` | 所有读请求只发给 Follower peer | 读写分离，可容忍亚秒级延迟 |
| `leader-and-follower` | 读请求在 Leader 和 Follower 间负载均衡 | 高吞吐场景，最大程度分散压力 |
| `closest-adaptive` | 优先选择网络延迟最低的副本（可能是 Leader 或 Follower） | 多数据中心部署，降低跨 AZ 延迟 |

#### Raft 日志延迟保证

Follower Read 通过 Raft 协议的 **Read Index** 机制保证数据一致性：

1. 读请求到达 Follower 后，Follower 向 Leader 请求当前的 committed index
2. Leader 返回 committed index，Follower 等待本地 apply 达到该 index
3. Follower 在本地以 snapshot 读取数据

这意味着 Follower Read 不会读到未 commit 的数据，但与 Leader 之间可能存在 **apply lag**（通常 < 100ms）。

---

### 4. Stale Read（有界延迟读取）

```sql
SET SESSION tidb_read_staleness = -5;
SELECT city, COUNT(*), AVG(score) FROM t_follower GROUP BY city;
SET SESSION tidb_read_staleness = '';
```

`tidb_read_staleness = -5` 表示允许读取最多 5 秒前的历史数据。与 Follower Read 的区别：

| 特性 | Follower Read | Stale Read |
|------|--------------|------------|
| 数据新鲜度 | 实时（Read Index 保证） | 容忍 N 秒延迟 |
| Leader 交互 | 需要向 Leader 请求 Read Index | 无需 Leader 交互 |
| 一致性 | Snapshot consistency | Snapshot consistency（历史快照） |

---

### 5. 三种读取模式对比

| 模式 | 读目标 | 数据新鲜度 | Leader 压力 | 适用场景 |
|------|--------|-----------|------------|---------|
| Leader Read（默认） | 仅 Leader | 实时 | 最高 | OLTP 写后即读 |
| Follower Read | 仅 Follower | 实时（Read Index） | 低 | 读多写少、报表查询 |
| Stale Read | 任意副本 | T-N 秒前的快照 | 最低 | 历史报表、离线分析 |

---

### Follower Read 效果验证

在 3+ TiKV 节点集群上，可以通过以下方式验证效果：

```sql
-- 查看当前启用的读取模式
SHOW VARIABLES LIKE 'tidb_replica_read';

-- 通过 Grafana / TiDB Dashboard 监控 TiKV 节点请求分布
-- 路径：TiDB Dashboard → Key Visualizer → 观察各 TiKV 节点的 read flow
```

**预期效果**（实际取决于 Region 调度和节点数）：

- 单节点 Leader CPU 使用率下降 40%-60%
- Follower 节点 CPU 使用率上升（从几乎空闲到均衡利用）
- 总查询吞吐量可提升 2-4 倍（取决于集群规模）
