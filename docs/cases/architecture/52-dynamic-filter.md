# 多条件动态筛选索引设计

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['动态筛选', '联合索引', '多条件查询', 'ICP']" />

## 20 万慢：查询却慢到 180ms
电商商品搜索页，用户可以按分类、状态、价格范围任意组合筛选。商品表 20 万行，查询却慢到 **180ms**：

```sql
SELECT id, name, category_id, brand_id, price, status, sales
FROM t_goods
WHERE category_id = 10
  AND status = 1
  AND price BETWEEN 100 AND 500
ORDER BY sales DESC
LIMIT 20;
```

表上有三个单列索引 `idx_category`、`idx_status`、`idx_price`，看起来该有的索引都有了。为什么三个条件同时筛选还是这么慢？

这就是 **"多条件动态筛选"** 的经典困境--单列索引无法覆盖组合查询，优化器只能选一个索引，其余条件靠回表逐行过滤，大量回表是浪费的。

::: warning 真实场景
商品搜索、订单筛选、工单过滤、用户查询--凡是后台管理或搜索页支持多条件任意组合筛选的场景，单列索引都无法高效应对。条件越多，浪费的回表越多。
:::

## 问题分析

### bad.sql

```sql
-- 多条件组合筛选：category_id=10 AND status=1 AND price BETWEEN 100 AND 500
-- 只有单列索引，优化器可能选 idx_category 或 idx_status 之一
-- 选定一个索引后，其余条件只能回表逐行过滤，大量无效回表
SELECT id, name, category_id, brand_id, price, status, sales
FROM t_goods
WHERE category_id = 10
  AND status = 1
  AND price BETWEEN 100 AND 500
ORDER BY sales DESC
LIMIT 20;
```

### EXPLAIN 结果

```
+----+---------+------+---------------------------+--------------+---------+--------+----------+------------------------------------+
| id | table   | type | possible_keys             | key          | key_len | rows   | filtered | Extra                              |
+----+---------+------+---------------------------+--------------+---------+--------+----------+------------------------------------+
|  1 | t_goods | ref  | idx_category,idx_status,  | idx_category | 4       | 4000   | 11.11   | Using index condition; Using where |
|    |         |      | idx_price                 |              |         |        |          | Using filesort                     |
+----+---------+------+---------------------------+--------------+---------+--------+----------+------------------------------------+
```

### 为什么慢

三个条件 `category_id=10 AND status=1 AND price BETWEEN 100 AND 500`，但只有单列索引：

1. **优化器只能选一个索引**：选了 `idx_category`，定位到 category_id=10 的约 4000 行
2. **其余两个条件靠回表过滤**：这 4000 行全部回表到聚簇索引，读取 status 和 price 逐行判断
3. **filtered 仅 11.11%**：意味着约 89% 的回表是浪费的（不满足 status 和 price 条件）
4. **Using filesort**：ORDER BY sales 无索引支撑，需对筛选结果做文件排序
5. **无法利用索引消除无效行**：status 和 price 的过滤发生在回表之后

::: tip 为什么不用 index_merge
MySQL 有 index_merge 优化（合并多个单列索引），但有局限：index_merge 通常用于 OR 条件，AND 条件下优化器更倾向选一个最优索引；即使 merge，也需要对多个索引的结果取交集，开销不小；范围条件（price BETWEEN）的 merge 效率更低。
:::

::: tip 核心认知
`filtered=11.11%` 是关键信号--它告诉你"回表的行中只有 11% 是有用的"。回表越浪费，越需要把过滤条件下推到索引层。联合索引就是让多个条件在索引内同时生效。
:::

## 优化方案

### good.sql

```sql
-- 联合索引优化后：idx_category_status_price (category_id, status, price)
-- 三个条件都能利用索引：category_id 等值定位 + status 等值进一步过滤 + price 范围扫描
-- 大幅减少回表行数，只需对最终少量候选行回表取 name/brand_id/sales
-- 需先执行 setup-good.sql 创建联合索引
SELECT id, name, category_id, brand_id, price, status, sales
FROM t_goods
WHERE category_id = 10
  AND status = 1
  AND price BETWEEN 100 AND 500
ORDER BY sales DESC
LIMIT 20;
```

### 建索引语句

```sql
-- setup-good.sql: 替换单列索引为联合索引
-- 联合索引 (category_id, status, price) 设计依据:
--   1. category_id 等值查询 -> 放最左，定位最精准
--   2. status 等值查询 -> 放第二，进一步缩小范围
--   3. price 范围查询 -> 放最后，利用索引有序性做范围扫描
-- 等值列在前、范围列在后
ALTER TABLE t_goods DROP INDEX idx_category;
ALTER TABLE t_goods DROP INDEX idx_status;
ALTER TABLE t_goods DROP INDEX idx_price;
ALTER TABLE t_goods ADD KEY idx_category_status_price (category_id, status, price);
```

### 原理

联合索引 `(category_id, status, price)` 的设计精妙之处在于列顺序：

```
idx_category_status_price (category_id, status, price)
         1                   2            3
         等值                等值          范围
         选择性高             选择性低      范围放最后
```

1. **等值列在前**：category_id=10 和 status=1 是等值查询，放索引最前，精准定位
2. **范围列在后**：price BETWEEN 是范围查询，放最后利用索引有序性做范围扫描
3. **三条件同时利用索引**：category_id 定位 -> status 等值 -> price 范围，全部在索引内完成
4. **ICP 下推**：`Using index condition` 表示 price 范围过滤下推到索引层，回表前就排除无效行
5. **回表量大减**：从 bad 的 4000 行回表降到 good 的约 444 行，减少约 89%

联合索引列顺序设计原则：

- **等值查询列放前面**：能精准定位，减少扫描范围
- **范围查询列放最后**：范围条件之后的列无法利用索引有序性（索引列截断）
- **高选择性列优先**：category_id 有 50 个值，区分度高于 status（3 个值）

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_category', rows: '4,000', filtered: '11.11%', Extra: 'Using index condition; Using where; Using filesort' }"
  :good="{ type: 'range', key: 'idx_category_status_price', rows: '444', filtered: '100%', Extra: 'Using index condition' }"
  improvement="扫描行数从 4000 降到 444，filtered 从 11% 到 100%，耗时下降约 12 倍"
/>

## 量化对比

| 指标 | bad (单列索引) | good (联合索引) | 提升 |
|------|---------------|-----------------|------|
| 扫描行数 | ~4,000 | ~444 | **约 9 倍** |
| 回表行数 | ~4,000 | ~444 | **约 9 倍** |
| filtered | 11.11% | 100% | **零浪费** |
| 耗时 | ~180 ms | ~15 ms | **约 12 倍** |
| Extra | Using where + filesort | Using index condition | ICP 下推 |

## 避坑指南

::: warning 注意事项

1. **动态筛选无法用单一索引覆盖所有组合**：根据最常见查询模式设计联合索引，覆盖 80% 场景。

2. **等值在前、范围在后**：这是联合索引列顺序的黄金法则，违反会导致范围列后的索引失效。

3. **避免过度索引**：每个联合索引都有维护成本，3-4 列为宜，太多列索引体积大且更新慢。

4. **考虑覆盖排序**：如果 ORDER BY 列也能放入索引，可消除 filesort（如加 sales 列）。

5. **监控慢查询中不同筛选组合**：用 pt-query-digest 分析哪些组合最频繁，针对性建索引。

6. **终极方案**：筛选组合极其多样时，考虑 Elasticsearch 等搜索引擎，关系数据库做精确查询。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 联合索引方案 | ✅ 有效 | ✅ 有效 |
| ICP 下推 | ✅ 支持 | ✅ 支持 |
| 优化器选择 | 偶尔需要 hint 引导 | 更智能 |
| 降序索引 | ❌ 不支持 | ✅ 支持 |

::: tip 5.7 hint 引导
执行计划结构在两个版本上一致，联合索引方案都有效，ICP（Index Condition Pushdown）也都支持，Extra 都会显示 `Using index condition`。

差异在于：8.0 优化器对联合索引的选择更智能；5.7 偶尔需要用 `FORCE INDEX (idx_category_status_price)` 引导。如果 ORDER BY sales 希望走降序索引，8.0 可建 `(category_id, status, price, sales DESC)` 消除 filesort，5.7 不支持降序索引。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 52-dynamic-filter

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 52-dynamic-filter --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 52-dynamic-filter --no-seed
```
