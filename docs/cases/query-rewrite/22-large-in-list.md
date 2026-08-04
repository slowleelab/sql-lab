# 大 IN 列表优化

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['IN列表', '临时表', 'JOIN']" />

## 上千个 ID 的 IN 列表：优化器选错执行计划
批量查询传入上千个 ID 的 IN 列表：`WHERE user_id IN (1,2,3,...,1000)`。IN 列表过长时优化器可能选择低效执行计划。

## 问题分析

```sql
-- bad.sql: 大 IN 列表（子查询模拟）
SELECT * FROM t_order_in
WHERE user_id IN (SELECT user_id FROM (SELECT DISTINCT user_id FROM t_order_in LIMIT 1000) tmp);
```

大 IN 列表：解析开销大、优化器可能不走索引、内存消耗高。

## 优化方案

```sql
-- good.sql: 临时表 JOIN 替代大 IN 列表（setup-good.sql 创建临时表）
SELECT o.* FROM t_order_in o
INNER JOIN tmp_target_users t ON o.user_id = t.user_id;
```

将 ID 写入带主键的临时表，通过 JOIN 利用索引查找。

<ExplainCompare
  :bad="{ type: 'ALL/subquery', key: 'idx_user (可能不用)', rows: '200,000', Extra: '大IN列表解析+过滤' }"
  :good="{ type: 'ref JOIN', key: 'idx_user + PK(tmp)', rows: '1000 × 1', Extra: '临时表驱动，索引查找' }"
  improvement="大IN列表 -> 临时表JOIN，执行计划更稳定"
/>

## 避坑指南

::: warning 注意事项
1. **IN 列表上限**：`max_allowed_packet` 限制 SQL 长度，过长会报错。
2. **临时表选择**：数据量小用 ENGINE=MEMORY，大用 InnoDB 临时表。
3. **8.0 优化**：8.0 对 IN 列表做了优化，但临时表 JOIN 在所有版本都稳定。
:::

## 本地复现

```bash
./scripts/run-case.sh 22-large-in-list
```
