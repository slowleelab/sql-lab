# JOIN 小表驱动大表

<CaseMeta difficulty="⭐⭐" category="JOIN" versions="5.7 & 8.0" :tags="['JOIN', '驱动表', 'Nested Loop', 'STRAIGHT_JOIN']" />

## 活动表 5000 条驱动订单表：3 秒变 30ms
促销活动页需要查询某活动关联的订单详情。活动关联表只有 5000 条记录，订单表有 100 万条。查询却跑了 3 秒：

```sql
SELECT o.id, o.order_no, o.amount, o.status, p.discount
FROM t_order_big o
INNER JOIN t_promotion_ref p ON p.order_no = o.order_no
WHERE p.promotion_id = 1;
```

明明是 5000 行的小表 JOIN 100 万行的大表，为什么这么慢？

::: warning 真实场景
任何"小表 JOIN 大表"的场景：标签关联、活动关联、权限关联。如果优化器选错驱动表或 JOIN 列没有索引，性能灾难。
:::

## 问题分析

### bad.sql

```sql
-- 用 STRAIGHT_JOIN 强制大表 t_order_big 在前作为驱动表（演示最差情况）
SELECT STRAIGHT_JOIN
    o.id, o.order_no, o.amount, o.status, p.discount
FROM t_order_big o                              -- 100万行（驱动表）
INNER JOIN t_promotion_ref p ON p.order_no = o.order_no  -- 5000行（被驱动表，order_no 无索引）
WHERE p.promotion_id = 1;
```

### 为什么慢

MySQL 的 Nested Loop Join（嵌套循环连接）原理：

```
for each row in 驱动表:              -- 外层循环
    for each row in 被驱动表:        -- 内层循环
        if join_condition matches:
            output row
```

当 **大表驱动小表** 时：
- 外层循环：100 万次（遍历大表）
- 内层循环：每次在被驱动表（5000 行）中查找 `order_no` 匹配
- 如果被驱动表的 JOIN 列**没有索引**，每次查找 = 全表扫描 5000 行
- 总查找次数：1,000,000 × 5,000 = **50 亿次**（灾难）

即使优化器不犯这个错误，被驱动表 JOIN 列没有索引也会导致性能极差。

## 优化方案

### 方案：小表驱动大表 + 被驱动表 JOIN 列建索引

```sql
-- 1. 给被驱动表的 JOIN 列加索引
ALTER TABLE t_promotion_ref ADD KEY idx_order_no (order_no);

-- 2. 小表驱动大表
SELECT STRAIGHT_JOIN
    o.id, o.order_no, o.amount, o.status, p.discount
FROM t_promotion_ref p                           -- 5000行（驱动表）
INNER JOIN t_order_big o ON o.order_no = p.order_no  -- 100万行（被驱动表，order_no 有索引）
WHERE p.promotion_id = 1;
```

### 原理

**小表驱动大表**时：
- 外层循环：先筛选 `promotion_id = 1`，假设匹配 500 行
- 内层循环：对这 500 行，每次去大表通过 `idx_order_no` 索引查找，O(1)
- 总查找次数：500 × 1 = **500 次**

对比大表驱动小表的 50 亿次，**差了 7 个数量级**。

### 关键原则

| 要素 | 要求 |
|------|------|
| 驱动表 | 数据量小的表（经过 WHERE 过滤后更小的那个） |
| 被驱动表 | JOIN 列**必须有索引** |
| JOIN 列 | 两表的 JOIN 列类型要一致 |

<ExplainCompare
  :bad="{ type: '大表驱动(100万行)', key: '被驱动表无索引', rows: '50亿次查找', Extra: 'Nested Loop 全表扫描' }"
  :good="{ type: '小表驱动(500行)', key: 'idx_order_no', rows: '500次索引查找', Extra: 'eq_ref/ref 索引查找' }"
  improvement="查找次数 50亿 -> 500，差 7 个数量级"
/>

## 避坑指南

::: warning 注意事项

1. **被驱动表的 JOIN 列必须有索引**。这是 JOIN 优化的第一优先级，比驱动表选择更重要。

2. **让优化器自动选择驱动表**。通常 MySQL 优化器会自动选小表作为驱动表，不需要手动 `STRAIGHT_JOIN`。只在优化器选错时才强制指定。

3. **JOIN 列类型必须一致**。如果一边是 `VARCHAR` 另一边是 `CHAR`，或一边 `utf8` 另一边 `utf8mb4`，可能导致索引失效（类似隐式类型转换）。

4. **小表是"过滤后"的小表**。不是看表的总行数，而是看 WHERE 条件过滤后剩余的行数。一个 1000 万行的表，如果 WHERE 过滤后只剩 100 行，它也可以是驱动表。

5. **避免 USING WHERE 做 JOIN 条件**。`ON a.id = b.id AND a.status = 1` 中的 `a.status = 1` 应该放到 WHERE 而不是 ON 里（对 INNER JOIN 来说效果相同，但语义更清晰）。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| Nested Loop Join | ✅ | ✅ |
| Hash Join | ❌ 只有 BNL（Block Nested Loop） | ✅ 原生支持（无索引时更优） |
| 驱动表选择 | 优化器自动 | 优化器自动（更智能） |

::: tip 8.0 Hash Join
8.0.18+ 引入了 Hash Join，当被驱动表 JOIN 列没有索引时，不再用 BNL，而是用 Hash Join（先扫描小表建 hash 表，再扫描大表匹配），性能好很多。但这不意味着可以不建索引--有索引的 Nested Loop 仍然更快。
:::

## 本地复现

```bash
./scripts/run-case.sh 33-small-drive-large
```
