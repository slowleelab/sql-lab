# 索引合并 Index Merge 陷阱

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['index_merge', 'OR', 'UNION改写']" />

## 状态为 1 或者城市为北京"的用户列表
用户表有 `idx_status` 和 `idx_city` 两个单列索引。运营后台需要查询"状态为 1 或者城市为北京"的用户列表：

```sql
SELECT * FROM t_user_merge
WHERE status = 1
   OR city = '北京';
```

两个条件各自有索引，看起来应该很快。但 MySQL 优化器选择了 `index_merge(union)` 策略——分别扫描两个索引，再合并去重。当 `status=1` 匹配约 20 万行、`city='北京'` 匹配约 1 万行时，合并 21 万个主键值的开销反而比全表扫描还慢。

::: warning 真实场景
任何多条件 OR 查询都可能触发 index_merge。当各条件匹配的行数都很大时，index_merge 的合并排序开销会超过全表扫描，成为性能杀手。
:::

## 问题分析

### bad.sql

```sql
SELECT *
FROM t_user_merge
WHERE status = 1
   OR city = '北京';
```

### EXPLAIN 结果

```
+----+-------------+--------------+------------+-------------+---------------------+---------------------+---------+------+--------+----------+------------------------------------------------+
| id | select_type | table        | partitions | type        | possible_keys       | key                 | key_len | ref  | rows   | filtered | Extra                                          |
+----+-------------+--------------+------------+-------------+---------------------+---------------------+---------+------+--------+----------+------------------------------------------------+
|  1 | SIMPLE      | t_user_merge | NULL       | index_merge | idx_status,idx_city | idx_status,idx_city | 2,83    | NULL | 210000 |   100.00 | Using union(idx_status,idx_city); Using where  |
+----+-------------+--------------+------------+-------------+---------------------+---------------------+---------+------+--------+----------+------------------------------------------------+
```

### 为什么慢

`type=index_merge` 看起来"用了两个索引"，但实际执行流程是：

```
MySQL 执行流程:
1. 扫描 idx_status 索引，找到 status=1 的约 20 万个主键值
2. 扫描 idx_city 索引，找到 city='北京' 的约 1 万个主键值
3. 将两个结果集合并、排序、去重（union 操作）  ← 性能杀手
4. 对合并后的 21 万个主键值逐行回表读取完整数据
```

**第 3 步的合并排序是隐藏成本**。21 万个主键值需要排序去重，这个操作在内存中完成，但当结果集很大时，排序开销非常可观。再加上 21 万次回表，总耗时约 **850 ms**，远超全表扫描的 **350 ms**。

::: tip 核心认知
`index_merge` 不是"两个索引一起用就更快"。当各条件匹配的行数都很大时，合并排序的开销会超过全表扫描。index_merge 适合各条件匹配行数都很少的场景。
:::

## 优化方案

### good.sql

```sql
SELECT *
FROM t_user_merge
WHERE status = 1
UNION ALL
SELECT *
FROM t_user_merge
WHERE city = '北京'
  AND status != 1;
```

### 原理

将 OR 拆成两个独立查询，各自走自己的索引：

**第一个查询**：`WHERE status = 1` 走 `idx_status`，精确匹配约 20 万行，直接回表读取。

**第二个查询**：`WHERE city = '北京' AND status != 1` 走 `idx_city`，精确匹配约 1 万行，回表读取。`AND status != 1` 排除与第一个查询的交集，确保结果正确。

**UNION ALL**：简单拼接两个结果集，无需排序去重。

与 index_merge 的关键差异：
- **index_merge**：先合并 21 万个主键值（排序+去重），再统一回表 21 万次
- **UNION ALL**：两个查询各自独立执行，分别回表 20 万 + 1 万次，无需合并排序

### 对比

| | bad.sql | good.sql |
|---|---|---|
| type | index_merge | ref + ref |
| key | idx_status,idx_city | idx_status / idx_city |
| 合并操作 | 21 万主键排序去重 | 无（UNION ALL 直接拼接） |
| 回表次数 | 21 万次（合并后统一回表） | 20 万 + 1 万（各自独立回表） |
| 耗时 | ~850 ms | ~420 ms |

<ExplainCompare
  :bad="{ type: 'index_merge', key: 'idx_status,idx_city', rows: '210,000', Extra: 'Using union(idx_status,idx_city); Using where' }"
  :good="{ type: 'ref + ref', key: 'idx_status / idx_city', rows: '200,000 + 10,000', Extra: 'NULL / Using where' }"
  improvement="避免 index_merge 合并排序开销，耗时降低 50%"
/>

## 避坑指南

::: warning 注意事项

1. **index_merge 不是万能药**。当各条件匹配的行数都很大时（比如超过总行数的 10%），index_merge 的合并排序开销会超过全表扫描。此时应该考虑 UNION ALL 改写或强制全表扫描。

2. **UNION ALL vs UNION**。如果确认两个条件无交集，用 `UNION ALL`（无需去重，更快）；如果有交集需去重，用 `UNION`（会去重排序，但仍比 index_merge 高效）。本例通过 `AND status != 1` 排除交集，所以用 `UNION ALL`。

3. **监控 index_merge 的使用**。通过 `EXPLAIN` 或慢查询日志发现 `type=index_merge` 时，检查各条件匹配的行数。如果行数很大，考虑改写。

4. **不要盲目创建多个单列索引**。如果经常需要 OR 查询，考虑创建联合索引或调整查询逻辑，避免触发 index_merge。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| index_merge 支持 | 支持 | 支持 |
| UNION ALL 改写 | 有效 | 有效 |
| index_merge 实现 | 基本相同 | 略有优化，但核心开销相同 |
| 优化器选择 | 可能选择 index_merge | 可能选择 index_merge |

::: tip 两版通用
UNION ALL 改写在 5.7 和 8.0 上都能稳定避免 index_merge，是更可移植的方案。两版的 index_merge 实现基本相同，性能特征一致。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 15-index-merge-pitfall

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 15-index-merge-pitfall --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 15-index-merge-pitfall --no-seed
```
