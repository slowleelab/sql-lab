# GROUP BY filesort 优化

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['GROUP BY', 'Using temporary', '索引有序', '聚合']" />

## 场景痛点

运营后台的城市维度销售报表，每次打开要等 2 秒：

```sql
SELECT city, COUNT(*) AS cnt, AVG(amount) AS avg_amount
FROM t_order_stat
GROUP BY city;
```

50 万行数据，8 个城市，按理说聚合应该很快，但 EXPLAIN 显示 `Using temporary`。

::: warning 真实场景
任何 GROUP BY 报表查询，如果分组字段没有索引，都会产生临时表。数据量大了之后临时表可能落盘，性能断崖式下降。
:::

## 问题分析

### bad.sql

```sql
SELECT city, COUNT(*) AS cnt, AVG(amount) AS avg_amount
FROM t_order_stat
GROUP BY city;
```

### EXPLAIN 结果

```
+----+--------------+------+---------+------+--------+------------------+
| id | table        | type | key     | rows | Extra                          |
+----+--------------+------+---------+------+--------------------------------+
|  1 | t_order_stat | ALL  | NULL    | 498K | Using temporary                |
+----+--------------+------+---------+------+--------------------------------+
```

### 为什么慢

`city` 字段没有索引，GROUP BY 需要：

1. **全表扫描**（`type=ALL`）读取 50 万行
2. **创建临时表**（`Using temporary`）存放每个城市的聚合中间结果
3. 扫描过程中逐行更新临时表中对应城市的 COUNT 和 SUM
4. 最后从临时表输出结果

临时表在内存中用 `tmp_table_size` 限制，超过后**落盘到磁盘**，I/O 开销急剧增加。

::: tip 两个性能杀手
- `Using temporary`：需要临时表做分组/去重
- `Using filesort`：需要额外排序

GROUP BY 如果字段无索引，经常同时出现这两个。
:::

## 优化方案

### 方案：给分组字段加索引

```sql
-- 给 city 字段加索引
ALTER TABLE t_order_stat ADD KEY idx_city (city);

-- 同样的查询，但现在利用索引有序性
SELECT city, COUNT(*) AS cnt, AVG(amount) AS avg_amount
FROM t_order_stat
GROUP BY city;
```

### 原理

B+ 树索引天然有序。加了 `idx_city` 索引后：

1. 沿着索引扫描，相同 `city` 值的行**物理上连续存放**
2. MySQL 可以边扫描边聚合，相同城市连续处理完再处理下一个
3. **不需要临时表**来暂存中间结果 -> `Using temporary` 消失

### 对比

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '498,616', Extra: 'Using temporary' }"
  :good="{ type: 'index', key: 'idx_city', rows: '498,616', Extra: 'NULL (无临时表)' }"
  improvement="消除 Using temporary，不再需要临时表做分组"
/>

::: tip 注意
全量 GROUP BY（无 WHERE）场景下，索引全扫描的绝对耗时不一定更快，因为仍需扫描全部行。但核心价值是**消除临时表**。配合 WHERE 过滤条件时，索引可以缩小扫描范围，优势更显著。
:::

## 避坑指南

::: warning 注意事项

1. **GROUP BY 字段尽量有索引**。这是最直接的优化手段。

2. **联合索引的列顺序要匹配 GROUP BY**。`GROUP BY a, b` 需要 `KEY(a, b)` 而不是 `KEY(b, a)`。

3. **WHERE 比 GROUP BY 先生效**。如果有 WHERE 过滤，优先保证 WHERE 条件走索引，再考虑 GROUP BY。

4. **8.0 的变化**：MySQL 8.0 默认 `group_by_no_index_without_orderby` 行为改变，GROUP BY 不再隐式排序（5.7 会隐式 ORDER BY）。如果需要有序结果，显式写 ORDER BY。

5. **临时表调优**：如果实在加不了索引，可以调大 `tmp_table_size` 和 `max_heap_table_size` 让临时表尽量留在内存。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| GROUP BY 隐式排序 | ✅ 默认排序 | ❌ 不再隐式排序 |
| 需要排序时 | 自动 | 显式加 ORDER BY |
| Using temporary 消除 | 加索引后消除 | 同 5.7 |

## 本地复现

```bash
./scripts/run-case.sh 21-group-by-filesort
```
