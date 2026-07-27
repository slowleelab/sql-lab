# EXPLAIN 参考结果 - good.sql（WHERE 提前过滤 status，只分组 25 万行）

> 本案例无 setup-good.sql，bad/good 差异在于 SQL 改写方式。

## MySQL 8.0（实测 8.0.46，100 万行数据）

```
+----+-------------+----------------+------------+------+---------------+-----------+---------+-------+--------+----------+------------------------------+
| id | select_type | table          | partitions | type | possible_keys | key       | key_len | ref   | rows   | filtered | Extra                        |
+----+-------------+----------------+------------+------+---------------+-----------+---------+-------+--------+----------+------------------------------+
|  1 | SIMPLE      | t_order_having | NULL       | ref  | idx_status    | idx_status| 2       | const | 249614 |   100.00 | Using where; Using index     |
+----+-------------+----------------+------------+------+---------------+-----------+---------+-------+--------+----------+------------------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 索引等值查找 |
| possible_keys | `idx_status` | status 索引可用 |
| key | `idx_status` | 使用 status 索引精确过滤 |
| key_len | `2` | TINYINT + NULL 标记 = 2 字节 |
| rows | ~249,614 | 预估扫描约 25 万行（status=1 占 1/4） |
| filtered | 100.00% | 所有扫描行都满足条件 |
| Extra | `Using where; Using index` | 覆盖索引扫描，无需回表 |

## 为什么快

`WHERE status = 1 GROUP BY user_id HAVING cnt > 5` 的执行流程：

1. **WHERE 提前过滤**：`status = 1` 在分组前过滤，通过 `idx_status` 索引精确定位约 25 万行
2. **减量分组**：只对这 25 万行按 `user_id` 分组，计算每组的 `COUNT(*)` 和 `SUM(amount)`
3. **HAVING 过滤**：分组完成后，只过滤聚合条件 `cnt > 5`

与 bad 方案的关键差异：
- **bad**：无 WHERE 过滤，对 100 万行做分组聚合，HAVING 才过滤 status
- **good**：WHERE 提前过滤 status=1，只对 25 万行做分组聚合

分组计算量从 100 万行降至 25 万行，减少 75%。虽然 good 方案使用了 `idx_status` 而非 `idx_user_id`（可能产生 filesort），但 25 万行的 filesort 开销远小于 100 万行的分组聚合开销。

实际耗时：约 **180 ms**。

## 量化对比

| 指标 | bad.sql | good.sql | 提升 |
|------|---------|----------|------|
| 分组前行数 | ~998,456 | ~249,614 | 减少 75% |
| type | index | ref | 索引全扫描 → 索引等值查找 |
| key | idx_user_id | idx_status | 利用 status 索引过滤 |
| 分组计算量 | 100 万行分组 | 25 万行分组 | 减少 75% |
| 耗时 | ~680 ms | ~180 ms | **3.8 倍** |

## 核心原则

**HAVING 中的非聚合条件应尽量提前到 WHERE 中**。WHERE 在分组前过滤，HAVING 在分组后过滤。将行级条件提前到 WHERE，可以大幅减少分组聚合的计算量。

## 5.7 vs 8.0 差异

- 两版行为一致，都需要显式改写 SQL 才能将 HAVING 条件提前到 WHERE
- 优化器不会自动将 HAVING 中的非聚合条件下推到 WHERE
- 改写后的 SQL 在两版上执行计划一致，性能提升相同
