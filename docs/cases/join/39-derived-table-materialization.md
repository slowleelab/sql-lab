# 派生表物化优化

<CaseMeta difficulty="⭐⭐" category="JOIN优化" versions="5.7 & 8.0" :tags="['派生表', '子查询物化', '8.0优化', '条件下推']" />

## 派生表外过滤：100 次活跃用户查询
访问日志分析系统需要找出"访问次数超过 100 次的活跃用户"。20 万行访问日志，5000 个用户分组。开发同学用 FROM 子查询（派生表）包裹 GROUP BY，再在外层 WHERE 过滤：

```sql
SELECT *
FROM (
    SELECT user_id, COUNT(*) AS cnt, AVG(response_time) AS avg_rt
    FROM t_access_log
    GROUP BY user_id
) t
WHERE cnt > 100
ORDER BY cnt DESC;
```

在 MySQL 5.7 上跑了 **420ms**。表面看数据量不大，但执行计划显示派生表被**完整物化**为临时表，物化了 5000 行分组结果后，外层再过滤掉约 2/3 不满足条件的行。

::: warning 真实场景
用派生表包裹聚合再外层过滤是开发常犯的写法。ORM 框架生成的 SQL 经常这样：先查一个子视图，再在应用层或外层 SQL 过滤。当分组基数达到百万级时，物化开销会显著放大。
:::

## 问题分析

### bad.sql

```sql
-- 派生表物化后外层过滤（5.7 无法下推）
--
-- 1. FROM 子查询 (SELECT user_id, COUNT(*) ... GROUP BY user_id) 是派生表
-- 2. MySQL 5.7 中派生表会被物化为临时表:
--    - 先执行子查询，将全部分组结果(5000行)物化到临时表
--    - 外层 WHERE cnt > 100 在物化后的临时表上过滤
--    - 无法将 cnt > 100 下推到子查询内部（HAVING）
-- 3. MySQL 8.0 优化器可做条件下推，但并非所有场景都能下推
SELECT *
FROM (
    SELECT
        user_id,
        COUNT(*)    AS cnt,
        AVG(response_time) AS avg_rt
    FROM t_access_log
    GROUP BY user_id
) t
WHERE cnt > 100
ORDER BY cnt DESC;
```

### EXPLAIN 结果

```
+----+-------------+------------+------------+------+---------------+-------------+---------+------+--------+----------+---------------------------------+
| id | select_type | table      | partitions | type | possible_keys | key         | key_len | ref  | rows   | filtered | Extra                           |
+----+-------------+------------+------------+------+---------------+-------------+---------+------+--------+----------+---------------------------------+
|  1 | PRIMARY     | <derived2> | NULL       | ALL  | NULL          | NULL        | NULL    | NULL |   5000 |   33.33  | Using where; Using filesort     |
|  2 | DERIVED     | t_access_log| NULL      | index| idx_user_id  | idx_user_id | 8       | NULL | 199430 |   100.00 | NULL                            |
+----+-------------+------------+------------+------+---------------+-------------+---------+------+--------+----------+---------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| 派生表 (id=2) | type=`index` | 扫描 idx_user_id 全索引 |
| 派生表 rows | ~199,430 | 扫描全部 20 万行日志 |
| 派生表 Extra | `NULL` | GROUP BY 利用索引有序，无额外排序 |
| 物化结果 | 5000 行 | **全部分组结果被物化到临时表** |
| 外层 (id=1) | type=`ALL` | 对物化临时表全扫描 |
| 外层 filtered | 33.33% | **外层 WHERE 过滤，仅 1/3 满足 cnt>100** |
| 外层 Extra | `Using where; Using filesort` | 物化后过滤 + 排序 |

### 为什么慢

**MySQL 5.7 行为**：

```
1. 子查询 SELECT user_id, COUNT(*) ... GROUP BY user_id 被完整执行
2. 全部 5000 个分组结果物化为临时表（DERIVED）
3. 外层 WHERE cnt > 100 在物化后的临时表上过滤，filtered=33.33%
4. 物化了 5000 行，但最终只需要约 1600 行（33.33%），浪费了 3400 行的物化开销
```

**MySQL 8.0 行为**：
- 8.0 优化器尝试条件下推，将 `cnt > 100` 下推为派生表内部 HAVING
- 但本案例中派生表 SELECT 了 `AVG(response_time)`，聚合函数混合使下推不总是生效
- 当下推失败时，行为与 5.7 一致：全量物化后外层过滤

**核心问题**：派生表物化在聚合前无法感知外层过滤条件，即使 8.0 也不保证下推成功。用派生表包裹 GROUP BY 再外层过滤，不如直接 HAVING 高效。

::: tip 核心认知
聚合过滤应直接用 `HAVING`，让优化器在聚合阶段就过滤，而非先物化全部结果再过滤。8.0 的条件下推是兜底优化，但不能替代正确的 SQL 写法。
:::

## 优化方案

### good.sql

```sql
-- 直接 GROUP BY HAVING，避免派生表物化
--
-- 1. 将外层 WHERE cnt > 100 改写为子查询内部的 HAVING COUNT(*) > 100
-- 2. 聚合时直接过滤，只产出满足条件的行，无需物化全部分组结果
-- 3. 5.7 中彻底避免派生表物化（没有 FROM 子查询了）
-- 4. 8.0 中虽然能下推，但直接 HAVING 仍更高效，省去派生表层
SELECT
    user_id,
    COUNT(*)           AS cnt,
    AVG(response_time) AS avg_rt
FROM t_access_log
GROUP BY user_id
HAVING COUNT(*) > 100
ORDER BY cnt DESC;
```

### 原理

1. **消除派生表**：不再有 FROM 子查询，单层 SIMPLE 查询
2. **HAVING 直接过滤**：`HAVING COUNT(*) > 100` 在聚合时直接判断，不产出不满足条件的行
3. **索引有序 GROUP BY**：`idx_user_id` 有序扫描，GROUP BY 无需临时表（Extra 为 NULL）
4. **无物化开销**：不创建 DERIVED 临时表，省去物化 + 外层扫描的代价

对比 bad 方案物化 5000 行再外层过滤，good 方案聚合时直接过滤，只产出约 1600 行。

### 对比

| | bad.sql (5.7) | bad.sql (8.0) | good.sql (5.7) | good.sql (8.0) |
|---|---|---|---|---|
| 耗时 | ~420 ms | ~380 ms | ~310 ms | **~260 ms** |
| 派生表物化 | 是(5000行) | 部分 | **无** | **无** |
| 临时表 | 有 | 可能 | **无** | **无** |
| filesort | 有 | 有 | 有 | **无** |

<ExplainCompare
  :bad="{ type: 'ALL (<derived2>)', key: 'NULL', rows: '5,000 (物化后)', Extra: 'Using where; Using filesort' }"
  :good="{ type: 'index', key: 'idx_user_id', rows: '199,430 -> 1,600', Extra: 'NULL (HAVING 直接过滤)' }"
  improvement="消除派生表物化，8.0 上从 380ms 降到 260ms，提升 1.6 倍"
/>

## 避坑指南

::: warning 注意事项

1. **聚合过滤用 HAVING，不要用派生表外层 WHERE**。`HAVING COUNT(*) > N` 在聚合阶段过滤，而派生表 + 外层 WHERE 是先物化全部结果再过滤，浪费物化开销。

2. **不要过度依赖 8.0 的条件下推**。8.0 的 derived condition pushdown 是重要优化，但有局限：仅对简单条件有效，混合聚合函数时可能无法下推，不能保证所有场景都生效。正确的 SQL 写法才是根本。

3. **GROUP BY 列要有索引**。本案例 `idx_user_id` 有序扫描让 GROUP BY 无需临时表。如果 GROUP BY 列没有索引，good 方案也会产生 `Using temporary; Using filesort`。

4. **当分组基数大时物化开销更显著**。本案例 5000 个分组尚可，但如果 user_id 基数达到百万级，派生表物化百万行的代价会急剧放大，good 方案的提升更显著。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 派生表处理 | 总是物化为临时表 | 延迟物化 + 条件下推 |
| 条件下推 | ❌ 不支持 | 部分支持（简单条件） |
| 索引有序 GROUP BY | 仍可能 Using filesort | 可完全消除 filesort |
| good 方案效果 | 消除物化，提升明显 | 消除物化 + 消除 filesort |

::: tip 8.0 条件下推
8.0 的派生表条件下推（derived condition pushdown）是重要优化，能将外层条件下推到派生表内部。但它有局限：仅对简单条件有效，混合聚合函数时可能无法下推。good 方案直接绕过派生表，两版本都受益。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 39-derived-table-materialization

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 39-derived-table-materialization --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 39-derived-table-materialization --no-seed
```
