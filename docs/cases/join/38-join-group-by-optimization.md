# JOIN + GROUP BY 聚合优化

<CaseMeta difficulty="⭐⭐⭐" category="JOIN优化" versions="5.7 & 8.0" :tags="['JOIN', 'GROUP BY', '聚合', '临时表', '先聚合后JOIN']" />

## 地区销售报表 2.7 秒：先聚合再 JOIN
BI 报表系统需要统计各地区的订单数和总金额。订单表 100 万行，用户表 1 万行，用户分布在 10 个地区。统计 SQL 跑了 **2.7 秒**：

```sql
SELECT
    u.region AS region,
    COUNT(*) AS order_count,
    SUM(o.amount) AS total_amount
FROM t_order o
INNER JOIN t_user u ON o.user_id = u.id
GROUP BY u.region
ORDER BY total_amount DESC;
```

最终结果只有 10 行（10 个地区），但查询却要处理 100 万行中间数据。问题出在**先 JOIN 再 GROUP BY**--100 万行 JOIN 结果全部进入临时表参与聚合。

::: warning 真实场景
任何"大表 JOIN 维度表再按维度属性聚合"的报表场景：订单按用户地区统计、流水按商户类型汇总、日志按来源 IP 归属地分组。只要 JOIN 在聚合之前执行，参与聚合的数据量就被放大到 JOIN 结果的大小。
:::

## 问题分析

### bad.sql

```sql
-- 先 JOIN 100 万行再 GROUP BY（大临时表）
--
-- 1. 先将 t_order(100万行) 与 t_user(1万行) 做 JOIN，产生 100 万行中间结果
-- 2. 对 100 万行中间结果按 u.region 做 GROUP BY 聚合
-- 3. GROUP BY 无法利用索引（region 在 t_user 上，JOIN 后顺序被打乱）
--    -> Using temporary; Using filesort
-- 4. 临时表需容纳 100 万行的 (region, order_count, total_amount) 聚合中间态
--    内存临时表放不下时溢出到磁盘，性能急剧下降
SELECT
    u.region                  AS region,
    COUNT(*)                  AS order_count,
    SUM(o.amount)             AS total_amount
FROM t_order o
INNER JOIN t_user u ON o.user_id = u.id
GROUP BY u.region
ORDER BY total_amount DESC;
```

### EXPLAIN 结果

```
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
| id | select_type | table | partitions | type   | possible_keys       | key                 | key_len | ref                     | rows   | filtered | Extra                        |
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
|  1 | SIMPLE      | u     | NULL       | index  | PRIMARY,idx_region  | idx_region          | 82      | NULL                    |  10000 |   100.00 | Using index                  |
|  1 | SIMPLE      | o     | NULL       | ref    | idx_user_id         | idx_user_id         | 8       | sql_treasure.u.id       |     98 |   100.00 | NULL                         |
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
```

（实际执行时 GROUP BY 阶段会产生 `Using temporary; Using filesort`）

| 字段 | 值 | 分析 |
|------|-----|------|
| u type | `index` | 用户表全索引扫描作为驱动表 |
| o type | `ref` | 订单表通过 idx_user_id 关联 |
| o rows | ~98 | 每用户平均 100 单（1万用户×100=100万） |
| JOIN 结果 | ~1,000,000 | **100 万行中间结果参与 GROUP BY** |
| GROUP BY Extra | `Using temporary; Using filesort` | 需要临时表 + 排序 |

### 为什么慢

执行流程：

```
1. 驱动表 t_user 全索引扫描 1 万行
2. 每行通过 idx_user_id 关联 t_order，平均每用户 100 单
3. JOIN 产生 100 万行中间结果
4. 对 100 万行按 u.region 做 GROUP BY
5. Using temporary -> 创建临时表存储 100 万行的聚合中间态
6. Using filesort -> 对最终 10 个地区结果排序
```

**核心问题**：GROUP BY 在 JOIN 之后执行，100 万行数据全部进入临时表参与聚合。当 `tmp_table_size` 不足时（默认 16MB），内存临时表溢出为磁盘临时表，性能下降一个数量级。

::: tip 核心认知
JOIN + GROUP BY 的性能取决于**参与聚合的数据量**，而非最终结果行数。先 JOIN 再 GROUP BY，聚合面对的是 JOIN 后的完整结果；先聚合后 JOIN，聚合面对的是大表内的数据，缩小后再 JOIN。
:::

## 优化方案

### good.sql

```sql
-- 先聚合后 JOIN（小结果集驱动）
--
-- 1. 子查询先在 t_order 表内按 user_id 聚合，100 万行 -> 1 万行
--    利用 idx_user_id 索引有序扫描，避免临时表（GROUP BY 走索引）
-- 2. 聚合结果(1万行) JOIN t_user(1万行) 按 region 做二次聚合
--    1 万行 JOIN 1 万行 -> 1 万行中间结果，再 GROUP BY region -> 10 行
-- 3. 最终临时表只处理 1 万行级别数据，内存即可容纳
SELECT
    u.region                  AS region,
    SUM(ot.order_count)       AS order_count,
    SUM(ot.total_amount)      AS total_amount
FROM (
    SELECT
        user_id,
        COUNT(*)              AS order_count,
        SUM(amount)           AS total_amount
    FROM t_order
    GROUP BY user_id
) ot
INNER JOIN t_user u ON ot.user_id = u.id
GROUP BY u.region
ORDER BY total_amount DESC;
```

### 原理

把查询拆成"先聚合后 JOIN"两步：

**第一步（子查询聚合）**：在 `t_order` 表内按 `user_id` 聚合，100 万行缩减为 1 万行。由于 `idx_user_id` 索引有序，GROUP BY 直接在索引上顺序聚合，**无需临时表**（Extra 为 NULL）。

```
子查询: t_order 按 idx_user_id 索引有序扫描 100 万行
  -> user_id 已有序，GROUP BY 顺序聚合
  -> 100 万行 -> 1 万行（每用户一行 order_count + total_amount）
  -> Extra: NULL（无 Using temporary!）
```

**第二步（外层 JOIN + 二次聚合）**：1 万行派生表 JOIN `t_user` 1 万行，主键 `eq_ref` 每次精确 1 行。再按 `region` 二次聚合为 10 行，临时表仅处理 1 万行级别数据。

对比 bad 方案的 100 万行进临时表，good 方案仅 1 万行进临时表，临时表数据量降低 **100 倍**。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 耗时 | ~2680 ms | **~780 ms** |
| 进临时表行数 | ~1,000,000 | **~10,000** |
| 子查询 GROUP BY | Using temporary | NULL（索引有序） |
| JOIN 中间结果 | 100 万行 | 1 万行 |

<ExplainCompare
  :bad="{ type: 'index', key: 'idx_region', rows: '1,000,000 (中间结果)', Extra: 'Using temporary; Using filesort' }"
  :good="{ type: 'index (子查询)', key: 'idx_user_id', rows: '10,000 (聚合后)', Extra: 'NULL 索引有序聚合' }"
  improvement="临时表数据量从 100 万行降到 1 万行，耗时下降约 3.4 倍"
/>

## 避坑指南

::: warning 注意事项

1. **大表的 GROUP BY 列必须有索引**。本案例子查询按 `user_id` 聚合能消除临时表，前提是 `idx_user_id` 索引有序。如果 GROUP BY 列没有索引，子查询内部也会产生 `Using temporary`。

2. **判断"先聚合后 JOIN"是否适用**。当大表需要按关联维度（如 user_id）聚合，再用小结果集 JOIN 维度表做最终聚合时，这个范式有效。如果聚合维度本身就 JOIN 列，则不能拆分。

3. **注意二次聚合的 SUM 嵌套**。外层 `SUM(ot.order_count)` 是对子查询已聚合的结果再做 SUM，语义正确但不要混淆。如果子查询有 AVG，外层不能简单 SUM 平均值，需要用 `SUM(total_amount)/SUM(order_count)` 重新计算。

4. **监控临时表是否溢出磁盘**。用 `SHOW STATUS LIKE 'Created_tmp_disk_tables'` 检查。如果 bad 方案溢出磁盘，性能差距会更大。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 先聚合后 JOIN 方案 | ✅ 有效 | ✅ 有效 |
| 派生表物化 | 总是物化为临时表 | 延迟物化 + 条件下推 |
| 索引有序 GROUP BY | 仍有 Using filesort 可能 | 可完全消除 filesort |
| 临时表引擎 | MEMORY -> MyISAM（溢出） | TempTable -> InnoDB（溢出） |

::: tip 8.0 派生表优化
8.0 优化器对派生表有条件下推优化，但本案例的优化核心是"先聚合缩小数据量"，两版本均有效。8.0 的 `idx_user_id` 索引有序 GROUP BY 可完全消除子查询临时表，性能更优。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 38-join-group-by-optimization

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 38-join-group-by-optimization --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 38-join-group-by-optimization --no-seed
```
