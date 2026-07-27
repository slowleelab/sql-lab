# 被驱动表无索引的灾难

<CaseMeta difficulty="⭐⭐" category="JOIN" versions="5.7 & 8.0" :tags="['JOIN', '被驱动表', '无索引', 'BNL']" />

## 场景痛点

订单主表 JOIN 订单明细表，明细表的 `order_id` 忘了建索引。10 万订单 + 30 万明细，查询直接卡死。

## 问题分析

```sql
-- bad.sql: 被驱动表 t_order_item.order_id 无索引
SELECT o.id, o.amount, i.product_name
FROM t_order_main o
JOIN t_order_item i ON i.order_id = o.id
WHERE o.user_id = 5000;
```

被驱动表 `type=ALL`，每次 JOIN 全表扫描 30 万行。驱动表每行去被驱动表全表扫描 = **灾难级性能**。

## 优化方案

```sql
-- setup-good.sql: ALTER TABLE t_order_item ADD KEY idx_order_id (order_id);
-- good.sql: 同样查询，被驱动表有索引
SELECT o.id, o.amount, i.product_name
FROM t_order_main o
JOIN t_order_item i ON i.order_id = o.id
WHERE o.user_id = 5000;
```

<ExplainCompare
  :bad="{ type: 'ALL (被驱动表)', key: 'NULL', rows: '300,000 × N', Extra: 'BNL 全表扫描' }"
  :good="{ type: 'ref (被驱动表)', key: 'idx_order_id', rows: '1 per lookup', Extra: '索引查找' }"
  improvement="被驱动表全表扫描 -> 索引查找，提升数千倍"
/>

## 避坑指南

::: warning 注意事项
1. **被驱动表 JOIN 列必须有索引** -- JOIN 优化第一优先级。
2. **8.0 Hash Join**：无索引时 8.0 用 Hash Join 替代 BNL，比 5.7 好但仍不如有索引。
3. **JOIN 列类型一致**：INT JOIN VARCHAR 会导致隐式转换，索引失效。
:::

## 本地复现

```bash
./scripts/run-case.sh 34-driven-no-index
```
