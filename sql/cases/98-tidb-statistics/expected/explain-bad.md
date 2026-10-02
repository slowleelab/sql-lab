# EXPLAIN 参考结果 - bad.sql（统计信息过期导致选错索引）

## TiDB v7.5.1（20 万初始 + 5 万新增 = 25 万行）

---

### 步骤 1: 初始统计健康度

```sql
SHOW STATS_HEALTHY WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
```

```
+-----------+------------+----------+---------+
| Db_name   | Table_name | Healthy  | State   |
+-----------+------------+----------+---------+
| sql_treasure | t_stats |      100 | healthy |
+-----------+------------+----------+---------+
```

`healthy = 100` 表示统计信息完全健康，没有任何数据变更未反映到统计信息中。

---

### 步骤 2: 统计健康时的 EXPLAIN（基线）

```sql
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexLookUp_7                 | 18000.00 | root      |                           |                                  |
| ├─IndexRangeScan_5(Build)     | 18000.00 | cop[tikv] | table:t_stats, index:idx_status | range:[1,1], keep order:false |
| └─Selection_6(Probe)          | 18000.00 | cop[tikv] |                           | eq(sql_treasure.t_stats.city, "Beijing") |
|   └─TableRowIDScan_7          | 18000.00 | cop[tikv] | table:t_stats             | keep order:false                 |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 优化器选择 | `idx_status` | status=1 约有 18 万行（90%），stats 认为选择性较好 |
| `estRows` | `18000.00` | 预估 1.8 万行结果（status=1 过滤后 city='Beijing' 再过滤约 10%） |
| task | `cop[tikv]` | Selection 过滤下推到 TiKV 层执行 |
| 健康度 | `healthy = 100` | 统计信息完全准确 |

---

### 步骤 3: 插入 5 万行后数据分布反转

```sql
SELECT status, COUNT(*) AS cnt, ROUND(COUNT(*) * 100 / 250000, 2) AS pct
FROM t_stats GROUP BY status ORDER BY status;
```

```
+--------+--------+-------+
| status | cnt    | pct   |
+--------+--------+-------+
|      0 |  70000 | 28.00 |
|      1 | 180000 | 72.00 |
+--------+--------+-------+
```

数据已经从 `status=0 占 10%` 变为 `status=0 占 28%`，但统计信息尚未更新——**stale stats**。

---

### 步骤 4: 统计过期后的 EXPLAIN（问题复现）

```sql
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexLookUp_7                 | 18000.00 | root      |                           | stats:pseudo                     |
| ├─IndexRangeScan_5(Build)     | 18000.00 | cop[tikv] | table:t_stats, index:idx_status | range:[1,1], keep order:false |
| └─Selection_6(Probe)          | 18000.00 | cop[tikv] |                           | eq(sql_treasure.t_stats.city, "Beijing") |
|   └─TableRowIDScan_7          | 18000.00 | cop[tikv] | table:t_stats             | keep order:false                 |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

#### 关键问题：`stats:pseudo`

`operator info` 中出现了 **`stats:pseudo`**——这是 TiDB 最危险的信号之一。它表示：

| 信号 | 含义 | 风险 |
|------|------|------|
| `stats:pseudo` | 该表没有真实统计信息（或统计严重过期），TiDB 使用伪统计估算 | `estRows` 偏差可达 **10-100 倍** |
| `estRows=18000` | 优化器仍按旧统计预估 | 实际 status=1 仍有 18 万行，但 status=0 已从 2 万涨到 7 万 |
| 健康度下降 | 大量写入后 `SHOW STATS_HEALTHY` 会显示 < 100 | DBA 应设置告警阈值（如健康度 < 80） |

#### 为什么会选错执行计划

1. **统计信息过期**：INSERT 了 5 万行后未执行 `ANALYZE`，TiDB 仍用旧统计
2. **伪统计估算**：当健康度降到某个阈值以下，TiDB 触发 `stats:pseudo`
3. **行数估算偏差**：优化器认为 status=1 仍是 18 万行（90%），但实际上分布发生了变化
4. **可能选错索引**：如果插入后 data 分布让 `idx_city` 更好，但优化器不知道，仍可能选 `idx_status`

#### TiDB 统计健康度机制

TiDB 通过 `modify_count` 和 `count` 的比值计算健康度：

```
健康度 = (1 - modify_count / count) * 100
```

当健康度低于 `tidb_auto_analyze_ratio`（默认 0.5，即 50%）时，TiDB 会自动触发 `ANALYZE`。但在本案例中，我们故意大批量写入后不等待自动 ANALYZE，模拟"写入后立即查询"的场景。

---

### stats:pseudo 的典型 EXPLAIN 信号

在 EXPLAIN 结果中查找以下危险信号：

| 信号 | operator info 中显示 | 严重程度 |
|------|---------------------|:--------:|
| `stats:pseudo` | 伪统计，无真实统计信息 | 严重 |
| `estRows` 与 `actRows` 差异大 | EXPLAIN ANALYZE 对比 | 严重 |
| 健康度低 | `SHOW STATS_HEALTHY` < 80 | 警告 |
| `modify_count` 高 | `SHOW STATS_META` modify_count / count > 0.1 | 警告 |
