# 范围查询后列索引失效

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['范围查询', '联合索引', '索引列顺序']" />

## 范围查询截断联合索引：amount 列白白失效
联合索引 `(user_id, status, amount)`，查询 `WHERE user_id=1000 AND status>1 AND amount>500`。`status` 用了范围查询，导致后面的 `amount` 无法走索引。

## 问题分析

```sql
-- bad.sql: status 范围查询截断了 amount 的索引使用
SELECT id, user_id, status, amount, created_at
FROM t_order_range
WHERE user_id = 1000 AND status > 1 AND amount > 500;
```

EXPLAIN: 只有 `user_id` 和 `status` 走索引，`amount` 在回表后逐行过滤。

**原因**：联合索引 B+ 树先按 `user_id` 排序，再按 `status` 排序。`status > 1` 是范围查询，匹配的行在索引中是连续的，但这些行的 `amount` 在索引中**不再有序**，无法用索引快速定位 `amount > 500`。

::: tip 核心规则
联合索引中，**范围查询列之后的列无法走索引**。这叫"范围截断"。
:::

## 优化方案

```sql
-- good.sql: status 改等值，三列都走索引
SELECT id, user_id, status, amount, created_at
FROM t_order_range
WHERE user_id = 1000 AND status = 2 AND amount > 500;
```

EXPLAIN: `type=range`, `key_len` 覆盖 `user_id + status`，`amount` 继续走范围扫描。

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_user_status_amount (2列)', rows: '~10000', Extra: 'Using where (amount回表过滤)' }"
  :good="{ type: 'range', key: 'idx_user_status_amount (3列)', rows: '~100', Extra: 'Using index condition' }"
  improvement="范围截断 -> 三列全走索引，扫描行数大幅减少"
/>

::: warning 如果业务确实需要范围查询 status
调整联合索引列顺序，遵循"**等值在前、范围在后**"原则：
- 原索引 `(user_id, status, amount)` -> 改为 `(user_id, amount, status)`
- 这样 `user_id`(等值) -> `amount`(范围) 走索引，`status` 在最后
:::

## 避坑指南

::: warning 注意事项
1. **范围操作符**：`>`, `>=`, `<`, `<=`, `BETWEEN`, `LIKE 'x%'` 都会截断后续列。
2. **等值不截断**：`=`, `IN` 是等值操作，不截断后续列。
3. **索引列顺序设计**：等值列放前面，范围列放最后。
4. **key_len 判断**：EXPLAIN 的 `key_len` 能看出用了几列索引。
:::

## 本地复现

```bash
./scripts/run-case.sh 07-range-after-index
```
