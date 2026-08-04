# 多表 JOIN 顺序控制

<CaseMeta difficulty="⭐⭐⭐" category="JOIN" versions="5.7 & 8.0" :tags="['多表JOIN', 'STRAIGHT_JOIN', 'JOIN顺序']" />

## 1000 行：优化器偶尔选错 JOIN 顺序
3 张表 JOIN（小表 1000 行、中表 5 万行、大表 20 万行），优化器偶尔选错 JOIN 顺序，先扫大表导致性能差。

## 问题分析

```sql
-- bad.sql: STRAIGHT_JOIN 强制最差顺序（大表 -> 中表 -> 小表）
SELECT STRAIGHT_JOIN s.*
FROM t_large l
JOIN t_medium m ON m.id = l.medium_id
JOIN t_small s ON s.id = m.small_id
WHERE s.val = 1;
```

大表先扫描 20 万行，每行去中表查，再从小表过滤 -- 驱动表太大导致大量无效查找。

## 优化方案

```sql
-- good.sql: STRAIGHT_JOIN 强制最优顺序（小表 -> 中表 -> 大表）
SELECT STRAIGHT_JOIN l.*
FROM t_small s
JOIN t_medium m ON m.small_id = s.id
JOIN t_large l ON l.medium_id = m.id
WHERE s.val = 1;
```

小表过滤后仅几行，驱动中表再驱动大表，每层都是索引查找。

<ExplainCompare
  :bad="{ type: 'ALL (大表驱动)', key: 'NULL', rows: '200,000', Extra: '大表先扫，无效查找多' }"
  :good="{ type: 'ref (小表驱动)', key: 'idx_small_id -> idx_medium_id', rows: '~10 -> 1', Extra: '逐层索引查找' }"
  improvement="大表驱动 -> 小表驱动，扫描行数大幅减少"
/>

## 避坑指南

::: warning 注意事项
1. **优先信任优化器**：8.0 优化器通常能选对 JOIN 顺序，`STRAIGHT_JOIN` 只在优化器选错时用。
2. **STRAIGHT_JOIN 的风险**：数据量变化后，手动指定的顺序可能不再最优。
3. **EXPLAIN ANALYZE**：8.0 用 `EXPLAIN ANALYZE` 看实际执行耗时，比 EXPLAIN 更准。
4. **驱动表选择原则**：WHERE 过滤后行数最少的表做驱动表。
:::

## 本地复现

```bash
./scripts/run-case.sh 36-join-order
```
