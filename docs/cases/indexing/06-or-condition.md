# OR 条件与索引合并

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['OR', 'index_merge', 'UNION改写']" />

## 整个查询退化为全表扫描
用户查询 `WHERE phone='13800138000' OR city='北京'`，`phone` 有索引但 `city` 没有。OR 中只要一侧无索引，整个查询退化为全表扫描。

## 问题分析

```sql
-- bad.sql: OR 连接两个条件，city 列无索引
SELECT id, username, phone, status, city, created_at
FROM t_user_or
WHERE phone = '13800138000' OR city = '北京';
```

EXPLAIN: `type=ALL`, `key=NULL` -- 全表扫描。

**原因**：OR 要求两侧都能快速定位才能用 index_merge。`city` 无索引，优化器直接放弃所有索引。

## 优化方案

```sql
-- good.sql: 用 UNION 改写（需先给 city 建索引）
SELECT id, username, phone, status, city, created_at
FROM t_user_or WHERE phone = '13800138000'
UNION
SELECT id, username, phone, status, city, created_at
FROM t_user_or WHERE city = '北京';
```

每个子查询独立走索引（`idx_phone` / `idx_city`），再合并去重。

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '300,000', Extra: 'Using where' }"
  :good="{ type: 'ref (两个子查询)', key: 'idx_phone + idx_city', rows: '~1 + ~60000', Extra: '各自走索引' }"
  improvement="OR改UNION，每个子查询独立走索引"
/>

## 避坑指南

::: warning 注意事项
1. **OR 两侧都有索引**时，MySQL 可能用 index_merge，但效果不如 UNION 稳定。
2. **UNION 会去重**，确认无重复用 `UNION ALL` 避免去重排序开销。
3. **优先用 IN 替代 OR**：`WHERE id IN (1, 2, 3)` 比 `id=1 OR id=2 OR id=3` 更高效。
4. **OR 两侧是同一列**时用 IN：`status=1 OR status=2` -> `status IN (1,2)`。
:::

## 本地复现

```bash
./scripts/run-case.sh 06-or-condition
```
