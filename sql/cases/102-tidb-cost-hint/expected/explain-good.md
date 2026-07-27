# EXPLAIN 参考结果 - good.sql（Hint 精细控制执行计划）

## TiDB v7.5.1（20 万行，通过 Hint 纠正优化器行为）

---

### 1. USE_INDEX / IGNORE_INDEX: 强制选择或忽略指定索引

```sql
EXPLAIN SELECT /*+ USE_INDEX(t_hint_test, idx_city) */ * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' LIMIT 20;
```

```
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| id                               | estRows  | task      | access object                | operator info                                        |
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
| Projection_9                     | 20.00    | root      |                              | sql_treasure.t_hint_test.id, ...                     |
| └─IndexLookUp_13                 | 20.00    | root      |                              |                                                      |
|   ├─IndexRangeScan_10(Build)     | 20000.00 | cop[tikv] | table:t_hint_test, index:idx_city | range:["Beijing","Beijing"], keep order:false |
|   └─Selection_12(Probe)          | 20.00    | cop[tikv] |                              | eq(sql_treasure.t_hint_test.status, 1)               |
|     └─TableRowIDScan_11          | 20000.00 | cop[tikv] | table:t_hint_test            | keep order:false                                     |
+----------------------------------+----------+-----------+------------------------------+------------------------------------------------------+
```

#### 关键变化（vs bad.sql 场景1）

| 指标 | bad.sql（默认 idx_status）| good.sql（USE_INDEX idx_city）| 改善 |
|------|--------------------------|------------------------------|------|
| 使用索引 | `idx_status` | **`idx_city`** | 强制走选择性更好的索引 |
| Build 阶段估计行数 | 18000（偏差大）| 20000（city='Beijing' 约 2 万行）| 估算准确 |
| Probe 阶段过滤 | Selection 过滤 city | Selection 过滤 status | 过滤条件位置交换 |
| 消除 TopN | 有 TopN（需排序）| **无 TopN** | LIMIT 20 直接取前 20 行（索引扫描顺序） |

```sql
EXPLAIN SELECT /*+ IGNORE_INDEX(t_hint_test, idx_status) */ * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' LIMIT 20;
```

```
（执行计划与 USE_INDEX(idx_city) 效果相同，优化器从剩余索引中选择 idx_city）
```

#### USE_INDEX / IGNORE_INDEX 对比

| Hint | 语义 | 适用场景 |
|------|------|---------|
| `USE_INDEX(t, idx)` | 建议优化器使用指定索引（非强制） | 当你知道某索引更适合当前查询 |
| `FORCE_INDEX(t, idx)` | **强制**使用指定索引（等同于 USE_INDEX in TiDB）| 排除其他所有索引 |
| `IGNORE_INDEX(t, idx)` | 排除指定索引 | 当某索引总是被错误选择 |

---

### 2. HASH_AGG / STREAM_AGG: 指定聚合算法

```sql
EXPLAIN SELECT /*+ HASH_AGG() */ city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;
```

```
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| id                          | estRows  | task      | access object                | operator info                                    |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| Projection_4                | 200000.00 | root     |                              | sql_treasure.t_hint_test.city, ...               |
| └─HashAgg_9                 | 200000.00 | root     |                              | group by:sql_treasure.t_hint_test.city, ...      |
|   └─TableReader_10          | 200000.00 | root     |                              | data:TableFullScan_8                             |
|     └─TableFullScan_8       | 200000.00 | cop[tikv] | table:t_hint_test           | keep order:false                                 |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
```

```sql
EXPLAIN SELECT /*+ STREAM_AGG() */ city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;
```

```
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| id                          | estRows  | task      | access object                | operator info                                    |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| Projection_4                | 200000.00 | root     |                              | sql_treasure.t_hint_test.city, ...               |
| └─StreamAgg_9               | 200000.00 | root     |                              | group by:sql_treasure.t_hint_test.city, ...      |
|   └─TableReader_11          | 200000.00 | root     |                              | data:TableFullScan_10                            |
|     └─TableFullScan_10      | 200000.00 | cop[tikv] | table:t_hint_test           | keep order:true                                  |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
```

#### HASH_AGG vs STREAM_AGG 对比

| 特性 | HASH_AGG | STREAM_AGG |
|------|---------|------------|
| 实现方式 | 构建 Hash Table 进行分组 | 要求数据按 group key 有序，流式处理 |
| 内存消耗 | 较高（需维护 Hash Table） | 较低（只需保存当前 group 的状态） |
| 输入要求 | 无顺序要求 | **必须按 group key 有序**（`keep order:true`） |
| 适用场景 | group 数量多（> 几百个） | group 数量少，或数据本身有序 |
| 本案例适用性 | 10 个城市，适合 | 10 个城市也适合，但需要额外排序 |

> **注意**：`STREAM_AGG` 要求输入有序，因此执行计划中出现 `keep order:true`，需要额外排序开销。如果 group 数量少，STREAM_AGG 更省内存；如果 group 数量多，HASH_AGG 更快。

---

### 3. READ_FROM_STORAGE: 指定从 TiKV 或 TiFlash 读取

```sql
EXPLAIN SELECT /*+ READ_FROM_STORAGE(TIKV[t_hint_test]) */ city, COUNT(*) FROM t_hint_test GROUP BY city;
```

```
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| id                          | estRows  | task      | access object                | operator info                                    |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| Projection_4                | 200000.00 | root     |                              |                                                  |
| └─HashAgg_9                 | 200000.00 | root     |                              | group by:...                                     |
|   └─TableReader_10          | 200000.00 | root     |                              | data:TableFullScan_8                             |
|     └─TableFullScan_8       | 200000.00 | cop[tikv] | table:t_hint_test           | keep order:false                                 |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
```

> 如果有 TiFlash 副本，`READ_FROM_STORAGE(TIFLASH[t_hint_test])` 会显示 `cop[tiflash]`，且可能触发 MPP 并行计算。

---

### 4. MAX_EXECUTION_TIME: 设置查询最大执行时间

```sql
SELECT /*+ MAX_EXECUTION_TIME(5000) */ COUNT(*) FROM t_hint_test;
```

```
+----------+
| COUNT(*) |
+----------+
|   200000 |
+----------+
1 row in set (0.01 sec)
```

如果查询执行超过 5000ms，TiDB 会自动中断并返回错误 `Query execution was interrupted (max_execution_time exceeded)`。

---

### 5. SET_VAR Hint: 会话级设置仅对当前语句生效

```sql
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_agg_push_down=OFF) */ city, COUNT(*) FROM t_hint_test GROUP BY city;
```

```
（HashAgg 的 task 变为 root，聚合不再下推）
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| id                          | estRows  | task      | access object                | operator info                                    |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| Projection_4                | 200000.00 | root     |                              |                                                  |
| └─HashAgg_9                 | 200000.00 | root     |                              | group by:...                                     |
|   └─TableReader_10          | 200000.00 | root     |                              | data:TableFullScan_8                             |
|     └─TableFullScan_8       | 200000.00 | cop[tikv] | table:t_hint_test           | keep order:false                                 |
+-----------------------------+----------+-----------+------------------------------+--------------------------------------------------+
```

```sql
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_limit_push_down_threshold=0) */ * FROM t_hint_test WHERE city = 'Beijing' LIMIT 20;
```

```
（LIMIT 不下推，TopN/Selection 在 root task 执行，而非 cop task）
```

#### SET_VAR 优势

`SET_VAR` 是最灵活的 Hint 之一：它允许对**单条 SQL** 临时修改系统变量，而不影响全局或会话级别的设置。对于需要临时关闭某个优化器开关来诊断问题的场景尤为实用。

---

### 6. MEMORY_QUOTA: 设置单条查询的内存限额

```sql
SELECT /*+ MEMORY_QUOTA(1073741824) */ COUNT(*) FROM t_hint_test;  -- 1 GB
```

如果查询内存使用超过限制，TiDB 会终止查询并报错。配合 `tidb_mem_oom_action` 变量可以控制行为。

---

### good.sql 优化总结

| 场景 | bad.sql（默认） | good.sql（Hint） | Hint 类型 |
|------|---------------|----------------|----------|
| 选错索引 | 优化器选 `idx_status` | 强制走 `idx_city` | `USE_INDEX` / `IGNORE_INDEX` |
| 聚合算法不确定 | 优化器自行选择 | 明确指定 `HASH_AGG` 或 `STREAM_AGG` | `HASH_AGG()` / `STREAM_AGG()` |
| 聚合未下推 | 默认行为 | 无需改动（ON 默认已下推） | — |
| 存储引擎不可控 | 自动路由 | 指定 `TIKV` 或 `TIFLASH` | `READ_FROM_STORAGE` |
| 查询无超时保护 | 可能长时间运行 | 5s 超时自动中断 | `MAX_EXECUTION_TIME` |
| 会话变量全局影响 | 需 SET SESSION | 单条 SQL 隔离修改 | `SET_VAR` |
| 内存溢出风险 | 默认内存限制 | 明确设置 1GB 上限 | `MEMORY_QUOTA` |

---

### TiDB Hint 速查表（10+ 种）

| 分类 | Hint | 语法 | 作用 |
|------|------|------|------|
| **索引控制** | `USE_INDEX` | `/*+ USE_INDEX(t, idx) */` | 建议使用指定索引 |
| | `FORCE_INDEX` | `/*+ FORCE_INDEX(t, idx) */` | 强制使用指定索引 |
| | `IGNORE_INDEX` | `/*+ IGNORE_INDEX(t, idx) */` | 忽略指定索引 |
| | `ORDER_INDEX` | `/*+ ORDER_INDEX(t, idx) */` | 指定排序索引（减少 Sort） |
| | `NO_ORDER_INDEX` | `/*+ NO_ORDER_INDEX(t, idx) */` | 禁止使用排序索引 |
| **Join 算法** | `HASH_JOIN` | `/*+ HASH_JOIN(t1, t2) */` | 使用 Hash Join |
| | `INL_JOIN` | `/*+ INL_JOIN(t1, t2) */` | 使用 Index Loop Join |
| | `MERGE_JOIN` | `/*+ MERGE_JOIN(t1, t2) */` | 使用 Merge Join（需有序） |
| | `INL_HASH_JOIN` | `/*+ INL_HASH_JOIN(t1, t2) */` | 使用 Index Loop Hash Join |
| | `INL_MERGE_JOIN` | `/*+ INL_MERGE_JOIN(t1, t2) */` | 使用 Index Loop Merge Join |
| **Join 顺序** | `LEADING` | `/*+ LEADING(t1, t2) */` | 指定 Join 顺序 |
| | `STRAIGHT_JOIN` | `/*+ STRAIGHT_JOIN() */` | 按 FROM 顺序 Join |
| **聚合算法** | `HASH_AGG` | `/*+ HASH_AGG() */` | 使用 Hash 聚合 |
| | `STREAM_AGG` | `/*+ STREAM_AGG() */` | 使用流式聚合 |
| **存储选择** | `READ_FROM_STORAGE` | `/*+ READ_FROM_STORAGE(TIKV[t]) */` | 指定 TiKV/TiFlash |
| **资源控制** | `MAX_EXECUTION_TIME` | `/*+ MAX_EXECUTION_TIME(ms) */` | 查询最大执行时间 |
| | `MEMORY_QUOTA` | `/*+ MEMORY_QUOTA(bytes) */` | 查询内存限额 |
| | `USE_TOJA` | `/*+ USE_TOJA() */` | 启用子查询优化（TopN-Join-Agg） |
| **变量修改** | `SET_VAR` | `/*+ SET_VAR(var=val) */` | 单条语句临时修改变量 |
| **其他** | `NO_INDEX_MERGE_JOIN` | `/*+ NO_INDEX_MERGE_JOIN() */` | 禁用 Index Merge Join |
| | `TIME_RANGE` | `/*+ TIME_RANGE(t, '...') */` | 指定表的时间范围（分区裁剪） |
| | `AGG_TO_COP` | `/*+ AGG_TO_COP() */` | 强制聚合下推 |
| | `LIMIT_TO_COP` | `/*+ LIMIT_TO_COP() */` | 强制 LIMIT 下推 |

> 注意：不同 TiDB 版本支持的 Hint 略有差异，请参考 [TiDB 官方文档 - Optimizer Hints](https://docs.pingcap.com/tidb/stable/optimizer-hints) 获取最新版本信息。
