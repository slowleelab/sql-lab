# EXPLAIN 参考结果 - bad.sql（未使用 Plan Cache）

## TiDB v7.5.1（10 万行）

---

### 场景1: 普通 SQL —— 每次重新优化

```sql
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 100;
```

```
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| id                            | estRows  | task      | access object                  | operator info                     |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| IndexLookUp_7                 | 10.00    | root      |                                |                                   |
| ├─IndexRangeScan_5(Build)     | 10.00    | cop[tikv] | table:t_plan_cache, index:idx_user | range:[100,100], keep order:false |
| └─TableRowIDScan_6(Probe)     | 10.00    | cop[tikv] | table:t_plan_cache             | keep order:false                  |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
```

```sql
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 200;
```

```
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| id                            | estRows  | task      | access object                  | operator info                     |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| IndexLookUp_7                 | 10.00    | root      |                                |                                   |
| ├─IndexRangeScan_5(Build)     | 10.00    | cop[tikv] | table:t_plan_cache, index:idx_user | range:[200,200], keep order:false |
| └─TableRowIDScan_6(Probe)     | 10.00    | cop[tikv] | table:t_plan_cache             | keep order:false                  |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
```

```sql
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 300;
```

```
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| id                            | estRows  | task      | access object                  | operator info                     |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| IndexLookUp_7                 | 10.00    | root      |                                |                                   |
| ├─IndexRangeScan_5(Build)     | 10.00    | cop[tikv] | table:t_plan_cache, index:idx_user | range:[300,300], keep order:false |
| └─TableRowIDScan_6(Probe)     | 10.00    | cop[tikv] | table:t_plan_cache             | keep order:false                  |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| 执行计划 | 三条 SQL 完全相同的计划结构（IndexLookUp） | 模式相同但每次都要完整走优化流程 |
| estRows | `10.00`（均分 10 万行 / 1 万 user_id） | 统计信息预估合理 |
| 优化器开销 | 每次都要解析 → 构建 AST → 逻辑优化 → 物理优化 | 高并发下 CPU 消耗不可忽略 |

---

### 场景2: Plan Cache 状态检查

```sql
SHOW VARIABLES LIKE 'tidb_enable_prepared_plan_cache';
```

```
+-------------------------------------+-------+
| Variable_name                       | Value |
+-------------------------------------+-------+
| tidb_enable_prepared_plan_cache     | ON    |
+-------------------------------------+-------+
```

```sql
SHOW GLOBAL STATUS LIKE 'Plan_cache%';
```

```
+--------------------------+-------+
| Variable_name            | Value |
+--------------------------+-------+
| Plan_cache_unmatched     | 0     |
| Plan_cache_evicted       | 0     |
| Plan_cache_hit_select    | 0     |
| Plan_cache_memory_usage  | 0     |
| Plan_cache_miss          | 0     |
| Plan_cache_hit_point_get | 0     |
| Plan_cache_hit           | 0     |
+--------------------------+-------+
```

| 状态变量 | 值 | 说明 |
|---------|-----|------|
| `Plan_cache_hit` | `0` | 所有 SQL 都未命中缓存（因为未使用 Prepared Statement） |
| `Plan_cache_miss` | `0` | 也未产生 miss（因为普通 SQL 根本不经过 Plan Cache 路径） |
| `Plan_cache_hit_select` | `0` | SELECT 类型命中数为 0 |
| `Plan_cache_evicted` | `0` | 无淘汰 |
| `Plan_cache_memory_usage` | `0` | 缓存内存占用为 0 |

---

### 场景3: 查看缓存内容

```sql
SELECT * FROM information_schema.cluster_plan_cache;
```

```
Empty set (0.00 sec)
```

Plan Cache 为空——普通 SQL 不会触发执行计划缓存。即使三条 SQL 的查询模板完全相同（只有 `user_id = ?` 的常量值不同），TiDB 也会将它们视为不同的 SQL 文本，每次都重新解析、重新优化、重新生成执行计划。

---

### 为什么普通 SQL 无法使用 Plan Cache

TiDB 的 Plan Cache 完全基于 **Prepared Statement 的 SQL 模板** 工作。当客户端通过 `PREPARE` 语句发送参数化 SQL 时，TiDB 在第一次 `EXECUTE` 时生成执行计划并缓存，后续 `EXECUTE` 只需绑定新的参数值即可直接复用。

普通 SQL（非 Prepare）每一次都是独立的文本，没有参数化机制，无法共享执行计划。这与 MySQL 8.0 的行为一致——MySQL Query Cache（5.7 时代）已被废弃，MySQL 8.0 同样只对 Prepared Statement 做 Plan Cache。

### 高并发后果

| 对比维度 | 普通 SQL（bad） | Prepared Statement（good） |
|---------|---------------|--------------------------|
| SQL 解析 | 每次重新解析 | 一次解析，复用 |
| 优化过程 | 每次完整优化 | 首次优化，后续跳过 |
| CPU 开销 | 高（30-50% 浪费在优化器） | 低 |
| Plan Cache 命中 | 始终为 0 | 第二次起命中 |
| 适用场景 | 低频查询 / 报表 | 高并发 OLTP |
