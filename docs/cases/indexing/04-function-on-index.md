# 函数操作致索引失效

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['函数索引', 'DATE', '索引失效']" />

## 30 万：created_at 有索引
运营后台按日期查订单，开发写了 `WHERE DATE(created_at) = '2026-07-01'`。`created_at` 有索引，但查询却全表扫描 30 万行。

## 问题分析

```sql
-- bad.sql: 对索引列套用 DATE() 函数
SELECT id, user_id, order_no, amount, created_at
FROM t_order_func
WHERE DATE(created_at) = '2026-07-01';
```

EXPLAIN: `type=ALL`, `key=NULL`, `rows=300,003` -- 索引失效。

**原因**：对列套用函数后，B+ 树中存的是原始 `DATETIME` 值，不是 `DATE()` 后的值，无法用索引查找。`DATE_FORMAT()`、`YEAR()`、`MONTH()` 等同理。

## 优化方案

```sql
-- good.sql: 改写为范围查询，不破坏索引
SELECT id, user_id, order_no, amount, created_at
FROM t_order_func
WHERE created_at >= '2026-07-01' AND created_at < '2026-07-02';
```

EXPLAIN: `type=range`, `key=idx_created`, `rows=402`。

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '300,003', Extra: 'Using where' }"
  :good="{ type: 'range', key: 'idx_created', rows: '402', Extra: 'Using index condition' }"
  improvement="扫描行数下降 99.87%，全表扫描 -> 索引范围扫描"
/>

## 避坑指南

::: warning 常见函数陷阱
1. `DATE(col)` / `DATE_FORMAT(col, ...)` -> 改用范围查询 `col >= '...' AND col < '...'`
2. `YEAR(col) = 2026` -> `col >= '2026-01-01' AND col < '2027-01-01'`
3. `col + 1 = 10` -> `col = 9`（运算放右边）
4. `LOWER(col) = 'abc'` -> 确保存储时统一小写，查 `col = 'abc'`
5. MySQL 8.0 支持函数索引 `CREATE INDEX idx ON t ((DATE(col)))`，但优先考虑改写 SQL
:::

## 本地复现

```bash
./scripts/run-case.sh 04-function-on-index
```
