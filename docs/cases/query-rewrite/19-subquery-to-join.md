# 子查询改写为 JOIN

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['子查询', 'JOIN改写', 'IN']" />

## IN 子查询太慢：5 万用户查"有订单的"
查询"有订单的用户"，开发用 `IN` 子查询。5 万用户 + 20 万订单，查询耗时偏高。

## 问题分析

```sql
-- bad.sql: IN 子查询
SELECT * FROM t_user_sub
WHERE id IN (SELECT user_id FROM t_order_sub);
```

8.0 优化器通常会将 IN 子查询优化为 semi-join，但 5.7 及某些场景下可能低效。

## 优化方案

```sql
-- good.sql: 改写为 INNER JOIN + DISTINCT
SELECT DISTINCT u.*
FROM t_user_sub u
INNER JOIN t_order_sub o ON u.id = o.user_id;
```

<ExplainCompare
  :bad="{ type: 'ALL + subquery', key: 'PRIMARY + auto_distinct_key', rows: '50000', Extra: '半连接' }"
  :good="{ type: 'index + eq_ref', key: 'idx_user_id + PRIMARY', rows: '200000 -> 1', Extra: 'Using index; Using temporary' }"
  improvement="子查询改JOIN，优化器有更多连接策略可选"
/>

::: tip 8.0 优化器
MySQL 8.0 对 IN 子查询做了大量优化（semi-join 转 JOIN），两种写法性能可能接近。但理解改写原理在 5.7 或优化器失效时很有价值。
:::

## 避坑指南

::: warning 注意事项
1. **DISTINCT 去重**：JOIN 会产生重复行（一个用户多个订单），需 DISTINCT 或 GROUP BY。
2. **NOT IN 的坑**：`NOT IN` 遇到 NULL 返回空结果，用 `NOT EXISTS` 或 `LEFT JOIN ... IS NULL`。
:::

## 本地复现

```bash
./scripts/run-case.sh 19-subquery-to-join
```
