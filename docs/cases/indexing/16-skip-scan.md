# 索引跳跃扫描 Skip Scan

<CaseMeta difficulty="⭐⭐" category="索引" versions="8.0" :tags="['Skip Scan', '联合索引', '低基数列', '索引跳跃']" />

## gender 低基数列也能走索引：8.0 Skip Scan
用户表有联合索引 `(gender, created_at)`，`gender` 只有 2 个值（M/F，低基数列）。现在需要查询 2026 年之后创建的用户：

```sql
SELECT * FROM t_user_skip
WHERE created_at > '2026-01-01';
```

查询条件只涉及 `created_at`，跳过了前导列 `gender`。按照最左前缀原则，这个索引应该用不了——MySQL 5.7 确实只能全表扫描。但 MySQL 8.0 引入了 **Skip Scan** 优化，理论上可以"跳跃"扫描索引。问题是：优化器不一定总是选择它。

::: warning 真实场景
任何联合索引的前导列是低基数列（如性别、状态、类型）时，查询跳过前导列都可能遇到这个问题。依赖优化器的 Skip Scan 决策不够稳定，显式展开前导列是更可靠的方案。
:::

## 问题分析

### bad.sql

```sql
SELECT *
FROM t_user_skip
WHERE created_at > '2026-01-01';
```

### EXPLAIN 结果

```
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table       | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_user_skip | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 498732 |    33.33 | Using where |
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

### 为什么慢

联合索引 `(gender, created_at)` 遵循**最左前缀原则**：查询条件必须包含前导列 `gender` 才能使用该索引。

`WHERE created_at > '2026-01-01'` 跳过了前导列 `gender`，MySQL 5.7 无法使用该索引，只能全表扫描 50 万行，逐行检查 `created_at` 条件。

MySQL 8.0 虽然支持 Skip Scan，但优化器选择不稳定：
- 优化器需要评估 Skip Scan 的成本，不一定总是选择它
- Skip Scan 需要扫描前导列的每个 distinct 值，再在每个值下做范围扫描
- 当前导列基数稍大时，Skip Scan 可能退化为多次索引扫描，效率不如预期

在本案例中，`gender` 只有 2 个值（M/F），Skip Scan 理论上可行，但优化器可能因统计信息不准确而放弃使用，最终选择全表扫描。

实际耗时：约 **180 ms**（全表扫描）。

::: tip 核心认知
Skip Scan 是 8.0 的优化特性，但不是银弹。优化器的选择不稳定，且效率不如直接使用前导列。显式展开前导列是两版通用的最佳实践。
:::

## 优化方案

### good.sql

```sql
SELECT *
FROM t_user_skip
WHERE gender IN ('M', 'F')
  AND created_at > '2026-01-01';
```

### 原理

显式展开前导列 `gender IN ('M','F')`，让联合索引 `(gender, created_at)` 完全生效：

```
MySQL 执行流程:
1. 在 gender='M' 的索引前缀下，利用 created_at > '2026-01-01' 做范围扫描
2. 在 gender='F' 的索引前缀下，利用 created_at > '2026-01-01' 做范围扫描
3. 合并两个范围扫描的结果
```

每个前缀下的扫描都是高效的索引范围扫描（`type=range`），且 `Using index` 表示覆盖索引扫描，无需回表读取数据行。

与 bad 方案的关键差异：
- **bad**：跳过前导列，无法使用索引，全表扫描 50 万行
- **good**：显式展开前导列，索引范围扫描约 16.6 万行，且是覆盖索引扫描

扫描行数从 50 万降至 16.6 万，且避免了回表操作，性能显著提升。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| type | ALL | range |
| key | NULL | idx_gender_created |
| rows | ~498,732 | ~166,244 |
| Extra | Using where | Using where; Using index |
| 耗时 | ~180 ms | ~45 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '498,732', Extra: 'Using where' }"
  :good="{ type: 'range', key: 'idx_gender_created', rows: '166,244', Extra: 'Using where; Using index' }"
  improvement="全表扫描转为索引范围扫描，扫描行数减少 67%，耗时降低 75%"
/>

## 避坑指南

::: warning 注意事项

1. **不要依赖 Skip Scan**。虽然 MySQL 8.0 支持 Skip Scan，但优化器的选择不稳定，且效率不如显式展开前导列。生产环境应该显式展开，确保执行计划稳定。

2. **前导列基数不能太大**。显式展开前导列的前提是前导列的 distinct 值很少（如性别、状态、类型）。如果前导列有几百上千个值，显式展开会导致 SQL 过长，此时应该考虑调整索引设计。

3. **IN 列表要完整**。显式展开时，`IN` 列表必须包含前导列的所有可能值，否则会漏数据。如果前导列可能新增值，需要同步更新 SQL。

4. **考虑索引设计**。如果经常需要跳过前导列查询，说明索引设计可能不合理。考虑将查询条件列作为前导列，或创建多个索引。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| Skip Scan 支持 | 不支持 | 支持（但优化器选择不稳定） |
| 显式展开前导列 | 有效 | 有效 |
| 执行计划稳定性 | 稳定（只能全表扫描或显式展开） | 不稳定（可能选择 Skip Scan 或全表扫描） |
| 推荐方案 | 显式展开前导列 | 显式展开前导列 |

::: tip 两版通用
显式展开前导列是 5.7 和 8.0 通用的最佳实践，不依赖优化器的 Skip Scan 决策，执行计划更稳定。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 16-skip-scan

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 16-skip-scan --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 16-skip-scan --no-seed
```
