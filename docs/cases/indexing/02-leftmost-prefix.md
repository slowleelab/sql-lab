# 联合索引最左前缀失效

<CaseMeta difficulty="⭐" category="索引" versions="5.7 & 8.0" :tags="['联合索引', '最左前缀', '索引失效']" />

## 联合索引没传第一列：50 万行全表扫描 2 秒
订单表建了联合索引 `(user_id, status, created_at)`，但后台报表查询时只按 `status` 和 `created_at` 过滤，没有传 `user_id`。50 万行的表查询要 2 秒，明明有联合索引却走全表扫描。

## 问题分析

```sql
-- bad.sql: 跳过了联合索引的最左列 user_id
SELECT id, user_id, order_no, status, amount, created_at
FROM t_order_latest
WHERE status = 1 AND created_at > '2026-01-01';
```

EXPLAIN: `type=ALL`, `key=NULL`, `rows=300,003` -- 联合索引完全失效。

**原因**：B+ 树联合索引按 `(user_id, status, created_at)` 排序。跳过 `user_id` 后，`status` 在索引中无序分布，无法二分查找定位。

::: tip 核心认知
联合索引遵循**最左前缀原则**：必须从最左列开始连续使用。跳过中间任何一列，后面的列都无法走索引。
:::

## 优化方案

```sql
-- good.sql: 补全最左前缀列 user_id
SELECT id, user_id, order_no, status, amount, created_at
FROM t_order_latest
WHERE user_id = 12345 AND status = 1 AND created_at > '2026-01-01';
```

EXPLAIN: `type=range`, `key=idx_user_status_created`, `rows=3` -- 三列都走索引。

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL (索引失效)', rows: '300,003', Extra: 'Using where' }"
  :good="{ type: 'range', key: 'idx_user_status_created', rows: '3', Extra: 'Using index condition' }"
  improvement="扫描行数下降 99.999%，30万行 -> 3行"
/>

## 避坑指南

::: warning 注意事项
1. **最左前缀不可跳过**：`(a,b,c)` 索引，查 `b` 和 `c` 不走索引，必须从 `a` 开始。
2. **中间列不能跳过**：查 `a` 和 `c`（跳过 `b`），只有 `a` 走索引，`c` 不走。
3. **等值条件可乱序**：`WHERE b=1 AND a=2` 优化器自动调整为 `(a,b)` 顺序。
4. **范围查询截断后续列**：详见 [案例 07](./07-range-after-index)。
:::

## 本地复现

```bash
./scripts/run-case.sh 02-leftmost-prefix
```
