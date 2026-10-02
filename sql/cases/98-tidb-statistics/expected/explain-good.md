# EXPLAIN 参考结果 - good.sql（ANALYZE 更新统计后恢复正确计划）

## TiDB v7.5.1（25 万行，ANALYZE 后）

---

### 步骤 1: ANALYZE TABLE

```sql
ANALYZE TABLE t_stats;
```

```
+------------------+---------+----------+----------+
| Table            | Op      | Msg_type | Msg_text |
+------------------+---------+----------+----------+
| sql_treasure.t_stats | analyze | status   | OK       |
+------------------+---------+----------+----------+
```

`ANALYZE TABLE` 重建了所有列的直方图、Count-Min Sketch 和统计元数据。

---

### 步骤 2: ANALYZE 后的统计健康度

```sql
SHOW STATS_HEALTHY WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
```

```
+-----------+------------+---------+---------+
| Db_name   | Table_name | Healthy | State   |
+-----------+------------+---------+---------+
| sql_treasure | t_stats |      100 | healthy |
+-----------+------------+---------+---------+
```

健康度恢复为 `100`，`stats:pseudo` 消失——优化器现在拥有准确的统计信息。

---

### 步骤 3: ANALYZE 后的 EXPLAIN（恢复正确）

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

#### 关键变化

| 指标 | bad.sql（stats:pseudo） | good.sql（ANALYZE 后） | 改善 |
|------|------------------------|----------------------|------|
| `stats:pseudo` | 存在于 operator info | **消失** | 统计恢复真实 |
| `estRows` | 18000.00（基于伪统计） | 18000.00（基于真实统计） | 准确反映数据分布 |
| 健康度 | < 100（stale） | **100** | 完全健康 |
| 执行计划稳定性 | 不可预测 | 可预测 | 优化器有可靠依据 |

---

### 步骤 4: 直方图信息

```sql
SHOW STATS_HISTOGRAMS WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
```

```
+-----------+------------+----------------+-------------+----------+---------------------+--------------+
| Db_name   | Table_name | Column_name    | Is_index    | Distinct | Null_count          | Last_updated |
+-----------+------------+----------------+-------------+----------+---------------------+--------------+
| sql_treasure | t_stats | id             | primary     |   250000 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | user_id        | 0           |   200000 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | status         | 0           |        2 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | city           | 0           |       10 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | amount         | 0           |     9987 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | created_at     | 0           |      365 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | idx_status     | 1           |        2 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | idx_city       | 1           |       10 |                   0 | 2026-07-28   |
| sql_treasure | t_stats | idx_user       | 1           |   200000 |                   0 | 2026-07-28   |
+-----------+------------+----------------+-------------+----------+---------------------+--------------+
```

`Is_index = 1` 的行表示索引列的直方图，`Is_index = 0` 表示普通列的直方图。`Distinct` 显示每列的不同取值数量。

---

### 步骤 5: 统计元数据

```sql
SHOW STATS_META WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
```

```
+-----------+------------+---------------------+--------+--------------+-----------+
| Db_name   | Table_name | Update_time         | Row_count | Modify_count | Snapshots |
+-----------+------------+---------------------+--------+--------------+-----------+
| sql_treasure | t_stats | 2026-07-28 12:00:00 |   250000 |            0 |         1 |
+-----------+------------+---------------------+--------+--------------+-----------+
```

| 字段 | 值 | 含义 |
|------|-----|------|
| `Row_count` | 250000 | ANALYZE 后更新的准确行数 |
| `Modify_count` | 0 | 自上次 ANALYZE 以来无修改（健康度 100） |
| `Update_time` | 最近一次 ANALYZE 时间 | 用于判断统计时效性 |

---

### bad.sql vs good.sql 量化对比

| 指标 | bad.sql（stale stats） | good.sql（ANALYZE） |
|------|----------------------|-------------------|
| 统计状态 | `stats:pseudo` 或过期 | 真实统计 |
| 健康度 | < 100 | 100 |
| `Modify_count` | > 0（大批量写入未反映） | 0 |
| `estRows` 准确性 | 偏差大（10-100x） | 接近实际 |
| 执行计划可靠性 | 不可预测 | 稳定可预测 |
| 优化器决策依据 | 伪统计/旧统计 | 真实直方图 + CM Sketch |

---

### ANALYZE 的三层统计结构

TiDB 的 `ANALYZE TABLE` 收集三层统计信息：

| 层级 | 统计类型 | 存储表 | 用途 |
|------|---------|--------|------|
| 表级 | 行数 (`Row_count`) | `mysql.stats_meta` | 估算全表扫描代价 |
| 列级 | 直方图 (Histogram) | `mysql.stats_histograms` + `mysql.stats_buckets` | 等值/范围查询的选择性估算 |
| 列级 | Count-Min Sketch | `mysql.stats_histograms` | 等值查询的基数估算（替代采样） |

当 `stats:pseudo` 出现时，这三层统计全部不可用，优化器退化为用**伪统计**（如每列假设 `Distinct/Row_count` 的固定比例）估算行数——这就是 `estRows` 严重失准的根本原因。
