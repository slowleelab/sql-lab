# EXPLAIN 参考结果 - bad.sql（优化器默认选择，status 倾斜导致选错索引）

## TiDB v7.5.1（20 万行，status 倾斜分布）

---

### 场景1: 高选择性 + 低选择性条件组合

```sql
EXPLAIN SELECT * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' ORDER BY score LIMIT 20;
```

```
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| id                               | estRows  | task      | access object                | operator info                                        |
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| Projection_9                     | 17.82    | root      |                              | sql_treasure.t_hint_test.id, ...                     |
| └─TopN_11                        | 17.82    | root      |                              | sql_treasure.t_hint_test.score, offset:0, count:20   |
|   └─IndexLookUp_20               | 17.82    | root      |                              |                                                      |
|     ├─IndexRangeScan_17(Build)   | 18000.00 | cop[tikv] | table:t_hint_test, index:idx_status | range:[1,1], keep order:false          |
|     └─TopN_19(Probe)             | 17.82    | cop[tikv] |                              | sql_treasure.t_hint_test.score, offset:0, count:20   |
|       └─Selection_18             | 18000.00 | cop[tikv] |                              | eq(sql_treasure.t_hint_test.city, "Beijing")         |
|         └─TableRowIDScan_19      | 18000.00 | cop[tikv] | table:t_hint_test            | keep order:false                                     |
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 优化器选择 | `idx_status` | 优化器认为 status=1 过滤后还有 18000 行 |
| **实际问题** | `estRows=18000.00` | **严重高估了 status=1 的选择性**：status=1 实际占 90%（18 万行），不是 18000 行 |
| 为什么选错 | 统计信息不准确 | 优化器低估了 status=1 的匹配行数，导致认为 idx_status 足够好 |
| 更好的选择 | `idx_city` | city='Beijing' 只占约 10%（~2 万行），选择性远高于 status=1 |
| `ORDER BY score LIMIT 20` | TopN 算子 | 需要先读取所有匹配行，再按 score 排序取前 20 |

#### 关键问题：优化器为何选错索引

1. **status 倾斜**：status=1 占 90%，真实选择性极差，但优化器可能因统计桶信息高估其选择性
2. **索引选择性估算偏差**：TiDB 的 cost model 通过直方图估算每个索引的扫描行数，倾斜分布下估算可能不准确
3. **LIMIT 与 ORDER BY 的干扰**：`ORDER BY score LIMIT 20` 需要 TopN 排序，优化器可能错误评估"先走 idx_status 再排序" vs "先走 idx_city 再排序"的成本

---

### 场景2: 聚合未下推（root task vs cop task）

```sql
EXPLAIN SELECT city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;
```

```
+-----------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| id                          | estRows  | task      | access object                | operator info                                        |
+-----------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| Projection_4                | 200000.00 | root     |                              | sql_treasure.t_hint_test.city, ...                   |
| └─HashAgg_9                 | 200000.00 | root     |                              | group by:sql_treasure.t_hint_test.city, ...          |
|   └─TableReader_10          | 200000.00 | root     |                              | data:TableFullScan_8                                 |
|     └─TableFullScan_8       | 200000.00 | cop[tikv] | table:t_hint_test           | keep order:false                                     |
+-----------------------------+----------+-----------+------------------------------+------------------------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| `HashAgg_9` | `task: root` | 聚合在 **TiDB Server 层**执行，未下推到 TiKV |
| `TableFullScan_8` | `task: cop[tikv]` | 全表扫描在 TiKV 完成 |
| `estRows` | 200000.00 | **20 万行全部从 TiKV 拉取到 TiDB Server**再做聚合 |
| 网络开销 | 巨大 | 20 万行的城市+分数数据从 TiKV 网络传输到 TiDB 层 |

当 `tidb_opt_agg_push_down = ON`（默认），TiDB 会将 `COUNT(*)` 和 `SUM(score)` 的聚合下推到 TiKV 层完成。如果该开关被关闭或在某些场景下未触发下推，聚合会在 root task 执行，导致性能下降。

---

### 场景3: 关键优化器开关状态

```sql
SHOW VARIABLES LIKE 'tidb_opt_agg_push_down';
SHOW VARIABLES LIKE 'tidb_opt_distinct_agg_push_down';
SHOW VARIABLES LIKE 'tidb_opt_limit_push_down_threshold';
SHOW VARIABLES LIKE 'tidb_enable_chunk_rpc';
```

```
+-------------------------------+-------+
| Variable_name                 | Value |
+-------------------------------+-------+
| tidb_opt_agg_push_down        | ON    |
| tidb_opt_distinct_agg_push_down | ON    |
| tidb_opt_limit_push_down_threshold | 100   |
| tidb_enable_chunk_rpc         | ON    |
+-------------------------------+-------+
```

#### 变量说明

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `tidb_opt_agg_push_down` | ON | 是否将聚合算子下推到 TiKV（减少网络传输） |
| `tidb_opt_distinct_agg_push_down` | ON | 是否将 DISTINCT 聚合下推到 TiKV |
| `tidb_opt_limit_push_down_threshold` | 100 | LIMIT ≤ 该值时可下推到 TiKV（减少不必要的数据读取） |
| `tidb_enable_chunk_rpc` | ON | 启用 Chunk 格式的 RPC，减少数据序列化开销 |

---

### bad.sql 问题诊断总结

| 问题 | 现象 | 根因 | 影响 |
|------|------|------|------|
| 选错索引 | 优化器选 `idx_status` 而非 `idx_city` | status 倾斜分布，统计估算偏差 | 扫描大量不必要行 |
| 聚合未下推（可能） | HashAgg 的 `task: root` | 某些场景下优化器未触发下推 | 20 万行网络传输 |
| TopN 排序开销 | ORDER BY score LIMIT 20 触发 TopN | 无法利用索引排序 | 需扫描所有匹配行后排序 |

---

### TiDB Cost Model 核心因子

优化器进行成本估算时，主要考虑以下因子：

| 因子 | 说明 | 系统变量 |
|------|------|---------|
| **行数估算 (estRows)** | 基于直方图/CM Sketch 估算各算子的输入行数 | 统计信息相关 |
| **网络开销** | cop task（下推）到 root task 的数据传输 | `tidb_opt_agg_push_down` |
| **CPU 开销** | HashAgg vs StreamAgg, Sort 等 CPU 密集操作 | `tidb_opt_limit_push_down_threshold` |
| **内存开销** | 算子所需内存（如 HashAgg 的 Hash Table） | `MEMORY_QUOTA` Hint |
| **磁盘开销** | 内存不足时的磁盘溢出 | `tidb_mem_quota_query` |
| **扫描类型** | IndexRangeScan vs TableFullScan 的 I/O 代价 | `tidb_enable_chunk_rpc` |
| **Join 顺序** | 多表 Join 时驱动表的选择 | `tidb_opt_join_reorder_threshold` |
