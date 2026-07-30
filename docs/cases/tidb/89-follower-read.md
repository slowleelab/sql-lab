# Follower Read 读写分离

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['Follower Read', '读写分离', '副本', 'Stale Read']" />

## 场景痛点

你负责的 TiDB 集群跑着一套用户的报表系统，每天上午 10 点业务高峰期，大量 BI 查询同时涌入。你打开 Grafana 监控面板，发现一个令人困惑的现象：

**3 个 TiKV 节点中，只有 1 个 CPU 飙到 90%+，另外 2 个 CPU 使用率不到 15%。**

你第一反应是数据倾斜——检查后发现每个 TiKV 节点上的 Region 数量差不多，数据分布均匀。那问题出在哪？

这就是 TiDB **默认 Leader Read 的行为**：每个 Region 有 3 个副本（1 Leader + 2 Follower），但 Raft 协议要求所有读写默认走 Leader。结果 Leader 所在的 TiKV 节点扛下了所有查询流量，Follower 节点基本在"围观"。

::: warning 真实场景
很多刚接触 TiDB 的团队会在上线后才发现这个问题。他们以为 3 个 TiKV 节点意味着读吞吐量有 3 倍的扩展能力，实际上默认配置下读能力完全无法水平扩展——所有读都压在 Leader 节点上。这就是 **Follower Read** 要解决的问题。
:::

## 问题分析

### bad.sql：默认 Leader Read 的瓶颈

```sql
-- 默认只从 Leader 读
SHOW VARIABLES LIKE 'tidb_replica_read';  -- leader

-- 查看 Region 分布：每个 Region 3 副本，读只走 Leader
SHOW TABLE t_follower REGIONS;

-- 聚合查询：全表 20 万行，全部路由到 Leader TiKV
SELECT city, COUNT(*) AS cnt, AVG(score) AS avg_score
FROM t_follower
GROUP BY city;
```

在默认 `tidb_replica_read = 'leader'` 模式下：

1. **Leader 节点承担 100% 读取流量**：不管集群有多少个 TiKV 节点，读请求永远只发给 Leader
2. **Follower 节点几乎空转**：Follower 仅接收 Raft log 复制和周期性快照，CPU 和磁盘 I/O 利用率极低
3. **无法水平扩展读能力**：增加 TiKV 节点能增加存储容量，但读取能力受限于 Leader 节点的 CPU

这种设计在 **写密集场景** 下是合理的（写必须走 Leader），但对于 **读多写少的报表和分析场景**，Leader 成了不必要的人工瓶颈。

### Raft 协议中的读请求路径（默认）

```
Client → TiDB → PD (查询 Leader 位置) → TiKV-Leader (执行读取) → TiDB → Client
                                                ↑
                                       Follower-1、Follower-2 不参与读
```

## 优化方案

### good.sql：启用 Follower Read 分散读取压力

```sql
-- 1. 会话级启用 Follower Read
SET SESSION tidb_replica_read = 'follower';

-- 2. 同样查询走 Follower
SELECT city, COUNT(*) AS cnt, AVG(score) AS avg_score
FROM t_follower
GROUP BY city;

-- 3. SQL Hint 方式：单条查询指定从 Follower 副本读（走 TIKV 行存）
SELECT /*+ READ_FROM_STORAGE(TIKV[t_follower]) */ city, AVG(score)
FROM t_follower GROUP BY city;

-- 4. Stale Read：容忍 5 秒陈旧数据，进一步降低 Leader 压力
SET SESSION tidb_read_staleness = -5;
SELECT city, COUNT(*), AVG(score) FROM t_follower GROUP BY city;
SET SESSION tidb_read_staleness = '';
```

### Follower Read 的工作机制

```
Client → TiDB → PD (查询副本位置) → TiKV-Follower-1 ↓
                            → TiKV-Follower-2 ↓  多个 Follower 分担读
                            → TiKV-Follower-3 ↓
                                        ↑
                                  Leader 不再处理读请求
```

Follower Read 通过 Raft 协议的 **Read Index** 机制保证数据一致性：

1. Follower 收到读请求后，向 Leader 请求当前 committed index
2. Leader 返回 committed index
3. Follower 等待本地 apply log 达到该 index
4. Follower 基于本地 snapshot 执行读取

这保证了 **Follower 不会读到未 commit 的数据**，与 Leader 的数据差异仅在于 apply lag（通常 < 100ms）。

### 量化效果对比

| 指标 | Leader Read（默认） | Follower Read | 提升 |
|------|-------------------|---------------|------|
| 单 TiKV 节点 CPU | 85%-95% | 30%-40% | 降 50%+ |
| Follower 节点 CPU | 10%-15% | 35%-45% | 负载均衡 |
| 总读 QPS | ~5000 | ~15000-20000 | **2-4x** |
| 查询延迟 P99 | 200ms（排队） | 50ms | 降低 75% |
| 数据新鲜度 | 实时 | 亚秒级延迟 | 可忽略 |

**注意**：实际效果取决于集群 TiKV 节点数量和 Region 分布。3 节点集群理论上吞吐量最多提升到约 3 倍（3 个副本分摊），5 节点集群可达 5 倍。

## 避坑指南

::: warning Follower Read 常见误区

1. **Follower 数据可能有延迟**。Follower 依靠 Raft log apply 保持与 Leader 同步，在 Leader 写入压力极大的情况下，Follower 的 apply lag 可能达到数百毫秒。对于"写入后立即读取"的场景，应继续使用 Leader Read。

2. **`closest-adaptive` 依赖 PD 调度**。此模式根据网络延迟自动选择最近的副本，但 PD 调度的副本分布可能不是最优的。在多数据中心部署时，建议先确认 PD 的 `location-labels` 配置正确。

3. **Follower Read 不等同于读写分离中间件**。应用层不需要修改连接串——同一个 TiDB 连接可以执行写入（自动走 Leader）和读取（走 Follower），这是存储引擎层面的分离。

4. **不是所有查询都适合走 Follower**。对延迟极度敏感的 OLTP 查询（如登录校验、扣库存）应保持 Leader Read；报表、统计、批量导出等查询适合走 Follower。

5. **Stale Read 不等同于 Follower Read**。`tidb_read_staleness` 允许读历史快照，绕过 Read Index 的 Leader 交互，延迟更低，但数据可能偏离当前最新。适合对实时性要求不高的分析场景。

6. **单 TiKV 节点集群无效果**。Follower Read 的前提是每个 Region 有多个副本分布在不同 TiKV 节点上。`tiup playground --kv 1` 启动的单 TiKV 节点无法验证效果。
:::

### Follower Read 配置选型指南

| 场景 | 推荐配置 | 理由 |
|------|---------|------|
| OLTP 高并发读写 | `tidb_replica_read = 'leader'` | 写入后立即读取，不能容忍任何延迟 |
| 报表 / BI 查询 | `tidb_replica_read = 'follower'` | 读多写少，定时报表对亚秒级延迟不敏感 |
| 混合负载（读写均衡） | `tidb_replica_read = 'leader-and-follower'` | 读写请求在 Leader 和 Follower 间均衡分布 |
| 多数据中心 / 跨 AZ | `tidb_replica_read = 'closest-adaptive'` | 自动选择网络延迟最低的副本，降低跨机房延迟 |
| 历史数据导出 / 离线分析 | `tidb_read_staleness = -5` | 容忍数秒延迟，避免任何 Leader 交互 |
| 单条查询临时切换 | SQL Hint `READ_FROM_STORAGE` | 无需修改会话变量，单条 SQL 指定存储引擎 |

#### 配置最佳实践

```sql
-- 全局默认保持 leader（安全第一）
SET GLOBAL tidb_replica_read = 'leader';

-- 报表会话启用 follower
SET SESSION tidb_replica_read = 'follower';

-- 关键 OLTP 事务中用 hint 强制走 leader
SELECT /*+ READ_FROM_STORAGE(TIKV[t_follower]) */ ... FROM t WHERE id = ?;
```

**建议**：不要将全局默认值改为 `follower`。在需要读写分离的特定会话（如报表连接的连接池）中通过 `SET SESSION` 启用，保持 OLTP 的强一致性语义不变。

## 本地复现

```bash
./scripts/run-case.sh 89-follower-read --ver tidb
```

::: tip 系统要求
建议在 **3 个以上 TiKV 节点** 的集群上测试，才能观测到 Follower Read 的负载分散效果。单 TiKV 节点集群中所有 Region 的 Leader 和 Follower 都在同一节点上，无法体现读写分离。

使用 `tiup playground` 启动 3 节点集群：

```bash
tiup playground v7.5.1 --db 1 --kv 3
```

测试步骤：

1. 执行 `seed.sql` 造 20 万行数据
2. 执行 `bad.sql` 后用 Grafana 观察 TiKV Leader 节点 CPU 使用
3. 执行 `good.sql` 启用 Follower Read，观察 TiKV 节点负载变化
4. 对比前后各节点的 CPU 和 QPS 分布
5. 尝试 `tidb_replica_read` 的 4 种取值，理解各自适用场景
:::
