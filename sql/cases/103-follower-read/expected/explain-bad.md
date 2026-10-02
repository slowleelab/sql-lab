# EXPLAIN 参考结果 - bad.sql（默认 Leader Read）

## TiDB v7.5.1（20 万行，3+ TiKV 节点集群）

---

### 查看 Follower Read 默认设置

```sql
SHOW VARIABLES LIKE 'tidb_replica_read';
```

```
+--------------------+-------+
| Variable_name      | Value |
+--------------------+-------+
| tidb_replica_read  | leader|
+--------------------+-------+
```

默认值为 `leader`，所有读取请求只发往各 Region 的 Leader peer。

---

### 查看 Region 分布

```sql
SHOW TABLE t_follower REGIONS;
```

```
+-----------+-----------------------------+-----------------------------+-----------+-----------------+------------------+
| REGION_ID | START_KEY                   | END_KEY                     | LEADER_ID | PEER_COUNT      | LEARNER_COUNT    |
+-----------+-----------------------------+-----------------------------+-----------+-----------------+------------------+
|      5001 | t_104_                      | t_104_r_500000              |      5004 |               3 |                0 |
|      5002 | t_104_r_500000              | t_104_r_1000000             |      5007 |               3 |                0 |
|      5003 | t_104_r_1000000             | t_104_r_1500000             |      5010 |               3 |                0 |
|      5004 | t_104_r_1500000             |                             |      5013 |               3 |                0 |
+-----------+-----------------------------+-----------------------------+-----------+-----------------+------------------+
```

每个 Region 有 3 个副本（Leader + 2 Follower），但 `tidb_replica_read = 'leader'` 时所有读请求只发往 LEADER_ID 对应的 TiKV 节点。

---

### 聚合查询 EXPLAIN（默认 Leader Read）

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

| 字段 | 值 | 分析 |
|------|-----|------|
| `TableFullScan_8` | `cop[tikv]` | 全表扫描在 TiKV 层执行 |
| 读取目标 | Leader peer | 所有 coprocessor 请求发往 Leader TiKV 节点 |
| HashAgg_9 | `root` | 聚合在 TiDB server 层完成 |
| 瓶颈 | Leader 节点 | 读写均集中在 Leader，CPU 和 I/O 压力大 |

---

### 默认 Leader Read 的负载特征

在默认 `tidb_replica_read = 'leader'` 模式下：

- **所有读写请求集中在 Leader 节点**：每个 Region 的 Leader 承担 100% 的读取流量
- **Follower 节点几乎空闲**（仅处理 Raft log 复制和快照）
- **Leader 节点 CPU/I/O 可能成为瓶颈**：高并发读场景下 Leader 节点的资源利用率远高于 Follower
- **无法水平扩展读吞吐量**：增加 TiKV 节点只增加副本数，不增加读取能力
