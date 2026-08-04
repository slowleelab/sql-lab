# 覆盖索引避免回表

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['覆盖索引', '回表', 'Using index', 'SELECT *']" />

## 列表页从 50ms 涨到 200ms：TEXT 回表是元凶
商品列表页展示「分类下的商品价格列表」，每页 100 条。数据库 30 万商品，查询耗时 50ms 还算能接受，但随着 TEXT 类型的 `description` 字段越来越大（商品详情越来越长），耗时逐渐飙升到 200ms+。

```sql
-- 列表页只需要 id, 分类, 价格，但开发偷懒用了 SELECT *
SELECT * FROM t_product
WHERE category_id = 50
ORDER BY price
LIMIT 100;
```

::: warning 真实场景
几乎所有列表页都有这个问题。开发习惯写 `SELECT *`，但列表页往往只需要几个字段。当表里有 TEXT/BLOB 长字段时，回表代价极高。
:::

## 问题分析

### bad.sql

```sql
SELECT *
FROM t_product
WHERE category_id = 50
ORDER BY price
LIMIT 100;
```

### EXPLAIN 结果

```
+----+-----------+------+-------------------+---------+-------+------+
| id | table     | type | key               | ref     | rows  | Extra |
+----+-----------+------+-------------------+---------+-------+-------+
|  1 | t_product | ref  | idx_category_price| const   | 2987  | NULL  |
+----+-----------+------+-------------------+---------+-------+-------+
```

看似不差：走了索引 `idx_category_price`，扫描 2987 行。但 **Extra 是 NULL**（没有 `Using index`），意味着需要回表。

### 为什么慢

`idx_category_price (category_id, price)` 索引中只有 `category_id`、`price` 和主键 `id`。

但 `SELECT *` 要求返回 `name`、`stock`、`description`（TEXT 长文本）、`status`、`created_at` 等所有字段，这些不在索引中。

MySQL 必须：
1. 从索引中找到 2987 条匹配的主键 id
2. **逐条回表**到聚簇索引读取完整行
3. 其中 `description` 是 TEXT 类型，可能存储在溢出页（off-page），**每次回表额外读一页**

2987 次回表 = 2987 次随机 I/O，TEXT 字段的溢出页 I/O 是主要瓶颈。

## 优化方案

### 方案：只查需要的字段，利用覆盖索引

```sql
-- good.sql
SELECT id, category_id, price
FROM t_product
WHERE category_id = 50
ORDER BY price
LIMIT 100;
```

### 原理

查询只取 `id`、`category_id`、`price` 三个字段：

- `category_id` -> `idx_category_price` 的第一列
- `price` -> `idx_category_price` 的第二列
- `id` -> InnoDB 二级索引自动附加主键

三个字段**全部在索引中**，MySQL 直接在索引上完成查询，**完全不回表**。

Extra 从 `NULL` 变为 **`Using index`**，这是覆盖索引的标志。

### 对比

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_category_price', rows: '2987', Extra: 'NULL (需回表)' }"
  :good="{ type: 'ref', key: 'idx_category_price', rows: '2987', Extra: 'Using index (不回表)' }"
  improvement="回表次数 2987 → 0，消除 TEXT 溢出页 I/O"
/>

### 进阶：如果确实需要更多字段

如果列表页还需要 `name` 和 `stock`，可以建一个更宽的联合索引：

```sql
ALTER TABLE t_product ADD KEY idx_covering (category_id, price, name, stock);
```

这样 `SELECT id, name, category_id, price, stock` 也能走覆盖索引。但索引越宽，写入和存储开销越大，需要权衡。

## 避坑指南

::: warning 注意事项

1. **永远不要 `SELECT *`**。只查需要的字段，这是最简单也最有效的优化。

2. **TEXT/BLOB 字段要分离**。如果商品详情是 TEXT，考虑拆到 `t_product_detail` 子表，列表查询不碰它。

3. **覆盖索引的代价**。索引越宽，INSERT/UPDATE/DELETE 越慢（需要维护更多索引页），磁盘占用也更大。只在高频查询的列上建覆盖索引。

4. **`Using index` ≠ `Using index condition`**。前者是覆盖索引（好），后者是索引下推 ICP（不同概念）。
:::

## 5.7 vs 8.0 差异

覆盖索引机制在两个版本中完全一致。`Using index` 的判定条件和行为没有变化。

## 本地复现

```bash
./scripts/run-case.sh 08-covering-index
```
