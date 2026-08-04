# STRAIGHT_JOIN 强制驱动顺序

<CaseMeta difficulty="⭐⭐⭐" category="JOIN" versions="5.7 & 8.0" :tags="['STRAIGHT_JOIN', 'JOIN顺序', '驱动表', '中间结果集']" />

## 50ms飙升
三表关联查询是后台报表系统的常见操作。某次大促后，运营反馈"订单详情页"接口从 50ms 飙升到 **2 秒**。排查发现：优化器选错了驱动表，先 JOIN 了 30 万行的订单明细表，产生巨大中间结果集，最后才过滤用户条件。

```sql
-- 三表 JOIN，优化器可能选错驱动表
SELECT *
FROM t_order_sj o
JOIN t_order_item_sj i ON o.id = i.order_id
JOIN t_product_sj p ON i.product_id = p.id
WHERE o.user_id = 100
  AND p.category = '电子';
```

::: warning 真实场景
三表及以上 JOIN 时，优化器的 JOIN 顺序选择对性能影响巨大。统计信息不准确、数据分布倾斜时，优化器可能选错驱动表，导致中间结果集爆炸。这类问题在数据量增长后才会暴露，排查难度高。
:::

## 问题分析

### bad.sql

```sql
SELECT *
FROM t_order_sj o
JOIN t_order_item_sj i ON o.id = i.order_id
JOIN t_product_sj p ON i.product_id = p.id
WHERE o.user_id = 100
  AND p.category = '电子';
```

### EXPLAIN 结果

```
+----+-------------+-------+------+--------------------+---------+--------+----------+-------------+
| id | select_type | table | type | key                | key_len | rows   | filtered | Extra       |
+----+-------------+-------+------+--------------------+---------+--------+----------+-------------+
|  1 | SIMPLE      | i     | ALL  | NULL               | NULL    | 298734 |   100.00 | NULL        |
|  1 | SIMPLE      | p     |eq_ref| PRIMARY            | 8       |      1 |    10.00 | Using where |
|  1 | SIMPLE      | o     |eq_ref| PRIMARY            | 8       |      1 |     5.00 | Using where |
+----+-------------+-------+------+--------------------+---------+--------+----------+-------------+
```

### 为什么慢

优化器选择了 `t_order_item_sj -> t_product_sj -> t_order_sj` 的 JOIN 顺序：

1. 先**全表扫描** `t_order_item_sj` 的约 30 万行
2. 对每行到 `t_product_sj` 做主键查找（30 万次），过滤 `category='电子'` 后剩约 3 万行
3. 再对每行到 `t_order_sj` 做主键查找（3 万次），过滤 `user_id=100` 后只剩约 1500 行

问题在于：真正的过滤条件 `o.user_id = 100`（命中约 2 个订单）在**最后一步**才生效。前面两步 JOIN 围绕约 30 万行中间结果集运作，绝大多数计算被丢弃。

## 优化方案

### good.sql

```sql
SELECT *
FROM t_order_sj o
STRAIGHT_JOIN t_order_item_sj i ON o.id = i.order_id
STRAIGHT_JOIN t_product_sj p ON i.product_id = p.id
WHERE o.user_id = 100
  AND p.category = '电子';
```

### 原理

`STRAIGHT_JOIN` 强制 JOIN 顺序为 `t_order -> t_order_item -> t_product`：

1. 先从 `t_order_sj` 过滤 `user_id = 100`（约 2 行）
2. 用这 2 行驱动 `t_order_item_sj`（`idx_order_id`，约 6 行）
3. 用这 6 行驱动 `t_product_sj`（主键，过滤 `category='电子'`）

每步 JOIN 都用小结果集驱动，中间结果集始终很小。

### 对比

| | bad.sql（优化器选错） | good.sql（STRAIGHT_JOIN） |
|---|---|---|
| 驱动表 | t_order_item_sj（30 万行） | t_order_sj（过滤后 2 行） |
| 驱动表扫描行数 | ~298,734 | ~2 |
| JOIN 顺序 | item -> product -> order | order -> item -> product |
| 耗时 | ~420 ms | ~2 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '298,734', Extra: '全表扫描做驱动表' }"
  :good="{ type: 'ref', key: 'idx_user_id', rows: '2', Extra: '索引过滤后只 2 行驱动' }"
  improvement="驱动表扫描行数从 30 万降到 2，耗时下降 210 倍"
/>

## 避坑指南

::: warning 注意事项

1. **STRAIGHT_JOIN 是强制的**，即使数据分布变化后原顺序不再最优，也不会自动调整。定期复查执行计划。

2. **只用于优化器确实选错的情况**。大多数场景优化器的选择是合理的，滥用 STRAIGHT_JOIN 反而可能导致性能退化。

3. **确保被驱动表有索引**。good 方案依赖 `idx_user_id` 和 `idx_order_id`，如果没有这两个索引，强制顺序也不会快。

4. **8.0 优化器更聪明**。8.0 的 hash join 和改进的统计信息减少了选错驱动表的概率，但复杂 JOIN 仍可能出错。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| STRAIGHT_JOIN | ✅ 支持强制顺序 | ✅ 支持强制顺序 |
| 优化器准确度 | 较低，更易选错 | 较高，统计信息更准 |
| Hash Join | ❌ 不支持 | ✅ 支持，减少对 JOIN 顺序的敏感度 |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 40-straight-join

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 40-straight-join --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 40-straight-join --no-seed
```
