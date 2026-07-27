# HAVING 改 WHERE 提前过滤

<CaseMeta difficulty="⭐" category="查询改写" versions="5.7 & 8.0" :tags="['HAVING', 'WHERE', 'GROUP BY', '提前过滤']" />

## 场景痛点

运营后台需要统计"已支付订单数大于 5 的用户"，SQL 写成了这样：

```sql
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM t_order_having
GROUP BY user_id
HAVING status = 1 AND cnt > 5;
```

看起来没问题，但 `status = 1` 是行级条件（非聚合条件），放在 HAVING 中会导致 MySQL 先对全部 100 万行订单做分组聚合，然后才过滤 status。实际上 status=1 只占约 25 万行（1/4），大量分组计算被浪费。

::: warning 真实场景
任何 GROUP BY 查询都可能踩到这个坑。HAVING 中的非聚合条件（如 status、type、category 等行级字段）应该尽量提前到 WHERE 中，避免对无关行做分组聚合。
:::

## 问题分析

### bad.sql

```sql
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM t_order_having
GROUP BY user_id
HAVING status = 1 AND cnt > 5;
```

### EXPLAIN 结果

```
+----+-------------+----------------+------------+-------+---------------+-------------+---------+------+--------+----------+----------------+
| id | select_type | table          | partitions | type  | possible_keys | key         | key_len | ref  | rows   | filtered | Extra          |
+----+-------------+----------------+------------+-------+---------------+-------------+---------+------+--------+----------+----------------+
|  1 | SIMPLE      | t_order_having | NULL       | index | idx_user_id   | idx_user_id | 8       | NULL | 998456 |   100.00 | Using index    |
+----+-------------+----------------+------------+-------+---------------+-------------+---------+------+--------+----------+----------------+
```

### 为什么慢

`GROUP BY user_id HAVING status = 1 AND cnt > 5` 的执行流程：

```
MySQL 执行流程:
1. 无 WHERE 过滤：status = 1 条件放在 HAVING 中，MySQL 无法在分组前过滤
2. 全量分组：对全部 100 万行订单按 user_id 分组，计算每组的 COUNT(*) 和 SUM(amount)
3. HAVING 过滤：分组完成后，才过滤 status = 1 和 cnt > 5
```

问题在于：`status = 1` 是行级条件，应该放在 WHERE 中提前过滤。status 0-3 均匀分布，status=1 只占约 25 万行（1/4）。bad 方案对 100 万行做分组，good 方案只需对 25 万行做分组，**分组计算量减少 75%**。

虽然 `idx_user_id` 索引让 GROUP BY 避免了 filesort（利用索引有序性），但分组聚合的计算量与行数成正比。100 万行的分组聚合耗时约 25 万行的 4 倍。

实际耗时：约 **680 ms**。

::: tip 核心认知
WHERE 在分组前过滤，HAVING 在分组后过滤。将行级条件提前到 WHERE，可以大幅减少分组聚合的计算量。HAVING 只应该用于聚合条件（如 COUNT、SUM、AVG 等）。
:::

## 优化方案

### good.sql

```sql
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM t_order_having
WHERE status = 1
GROUP BY user_id
HAVING cnt > 5;
```

### 原理

将 `status = 1` 从 HAVING 提前到 WHERE：

```
MySQL 执行流程:
1. WHERE 提前过滤：status = 1 在分组前过滤，通过 idx_status 索引精确定位约 25 万行
2. 减量分组：只对这 25 万行按 user_id 分组，计算每组的 COUNT(*) 和 SUM(amount)
3. HAVING 过滤：分组完成后，只过滤聚合条件 cnt > 5
```

与 bad 方案的关键差异：
- **bad**：无 WHERE 过滤，对 100 万行做分组聚合，HAVING 才过滤 status
- **good**：WHERE 提前过滤 status=1，只对 25 万行做分组聚合

分组计算量从 100 万行降至 25 万行，减少 75%。虽然 good 方案使用了 `idx_status` 而非 `idx_user_id`（可能产生 filesort），但 25 万行的 filesort 开销远小于 100 万行的分组聚合开销。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 分组前行数 | ~998,456 | ~249,614 |
| type | index | ref |
| key | idx_user_id | idx_status |
| 分组计算量 | 100 万行分组 | 25 万行分组 |
| 耗时 | ~680 ms | ~180 ms |

<ExplainCompare
  :bad="{ type: 'index', key: 'idx_user_id', rows: '998,456', Extra: 'Using index' }"
  :good="{ type: 'ref', key: 'idx_status', rows: '249,614', Extra: 'Using where; Using index' }"
  improvement="分组前行数减少 75%，分组计算量降低 75%，耗时降低 74%"
/>

## 避坑指南

::: warning 注意事项

1. **HAVING 只用于聚合条件**。HAVING 应该只包含聚合函数条件（如 `COUNT(*) > 5`、`SUM(amount) > 1000`），行级条件（如 `status = 1`、`type = 'A'`）应该放在 WHERE 中。

2. **优化器不会自动下推**。MySQL 优化器不会自动将 HAVING 中的非聚合条件下推到 WHERE，必须显式改写 SQL。

3. **WHERE vs HAVING 的执行时机**。WHERE 在分组前过滤，HAVING 在分组后过滤。提前过滤可以大幅减少分组聚合的计算量。

4. **索引选择可能变化**。改写后，MySQL 可能选择不同的索引（如本例从 `idx_user_id` 变为 `idx_status`），这是正常的。只要分组前行数减少，性能就会提升。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| HAVING 下推 | 不支持 | 不支持 |
| 显式改写 | 有效 | 有效 |
| 执行计划 | 一致 | 一致 |

::: tip 两版通用
5.7 和 8.0 都不会自动将 HAVING 中的非聚合条件下推到 WHERE，必须显式改写 SQL。改写后的 SQL 在两版上执行计划一致，性能提升相同。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 28-having-to-where

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 28-having-to-where --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 28-having-to-where --no-seed
```
