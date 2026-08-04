# 自连接查询优化

<CaseMeta difficulty="⭐⭐" category="JOIN优化" versions="5.7 & 8.0" :tags="['自连接', '索引设计', 'JOIN优化']" />

## 自连接 1.2 秒：10 万员工查"我的上级"
员工管理系统需要查询每个员工的直接上级姓名。员工表有 10 万行，`manager_id` 指向另一个员工的 `id`，这是一个典型的自连接场景。查询"技术部"所有员工及其上级姓名时，却跑了 **1.2 秒**：

```sql
SELECT
    e1.id AS emp_id, e1.emp_name, e1.department, e1.salary, e2.emp_name AS manager_name
FROM t_employee e1
LEFT JOIN t_employee e2 ON IFNULL(e1.manager_id, 0) = e2.id
WHERE e1.department = '技术部'
ORDER BY e1.id
LIMIT 100;
```

表上明明有 `idx_manager (manager_id)` 索引，为什么自连接还是这么慢？问题出在 `IFNULL()` 函数包裹了索引列。

::: warning 真实场景
自连接在组织架构、分类层级、评论楼层、菜单树等场景无处不在。开发同学习惯用 `IFNULL(manager_id, 0)` 或 `COALESCE(manager_id, 0)` 来处理 NULL 上级，却不知道这层"善意"的包裹直接让索引失效。
:::

## 问题分析

### bad.sql

```sql
-- 自连接但 manager_id 被函数包裹导致索引失效
--
-- schema 中已存在 idx_manager (manager_id) 索引，
-- 但本查询在 JOIN 条件中使用 IFNULL(e1.manager_id, 0) = e2.id，
-- 对索引列施加了函数包裹，导致优化器无法使用 idx_manager 索引。
-- 被驱动表 e2 只能走主键，但驱动表 e1 的 manager_id 列无法走索引定位，
-- 整个查询退化为对全表的扫描 + 主键逐行探测。
SELECT
    e1.id           AS emp_id,
    e1.emp_name     AS emp_name,
    e1.department   AS department,
    e1.salary       AS salary,
    e2.emp_name     AS manager_name
FROM t_employee e1
LEFT JOIN t_employee e2 ON IFNULL(e1.manager_id, 0) = e2.id
WHERE e1.department = '技术部'
ORDER BY e1.id
LIMIT 100;
```

### EXPLAIN 结果

```
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
| id | select_type | table | partitions | type | possible_keys       | key                 | key_len | ref   | rows   | filtered | Extra                                        |
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
|  1 | SIMPLE      | e1    | NULL       | ref  | idx_department      | idx_department      | 202     | const |   9968 |   100.00 | Using index condition; Using filesort        |
|  1 | SIMPLE      | e2    | NULL       | ALL  | PRIMARY             | NULL                | NULL    | NULL  |  99680 |   100.00 | Range checked for each record (index map: 0x1)|
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| e1 type | `ref` | 驱动表通过 idx_department 定位"技术部" |
| e1 Extra | `Using filesort` | ORDER BY 需要额外排序 |
| e2 type | `ALL` | **被驱动表全表扫描** |
| e2 key | `NULL` | **主键索引未被使用** |
| e2 rows | ~99,680 | 预估扫描约 10 万行 |
| e2 Extra | `Range checked for each record` | 每行重新评估索引，无法提前锁定索引 |

### 为什么慢

JOIN 条件 `IFNULL(e1.manager_id, 0) = e2.id` 对 `e1.manager_id` 施加了 `IFNULL()` 函数包裹。虽然 `e2.id` 是主键，但优化器无法将函数表达式与主键做等值匹配，只能对被驱动表 e2 逐行全表扫描。

执行流程：

```
1. 驱动表 e1 通过 idx_department 定位"技术部"约 1 万名员工
2. 对每个员工，执行 IFNULL(manager_id, 0) = e2.id
3. 由于函数包裹，e2 的主键索引无法被直接利用
   -> 显示 Range checked for each record
4. 每行关联都要在 e2 表上做一次范围检查，退化为接近全表扫描
5. 最终还需要 Using filesort 对结果排序
```

10 万行表上 1 万次驱动循环 × 10 万行扫描 = 约 **1 亿次**行检查。

::: tip 核心认知
对索引列施加任何函数（`IFNULL`、`COALESCE`、`DATE_FORMAT`、`+ 0` 等）都会导致索引失效。自连接的本质和普通 JOIN 一样：JOIN 条件列必须有可用索引，且不能被函数/运算包裹。
:::

## 优化方案

### good.sql

```sql
-- 移除函数包裹，让 manager_id 走索引
--
-- 1. 去掉 JOIN 条件中的 IFNULL() 函数包裹，直接用 e1.manager_id = e2.id
-- 2. seed 数据中 manager_id=0 的行表示无上级，LEFT JOIN 时 e2.id 无匹配返回 NULL
--    与 bad 方案 IFNULL(...,0) 的语义一致，但不破坏索引使用
SELECT
    e1.id           AS emp_id,
    e1.emp_name     AS emp_name,
    e1.department   AS department,
    e1.salary       AS salary,
    e2.emp_name     AS manager_name
FROM t_employee e1
LEFT JOIN t_employee e2 ON e1.manager_id = e2.id
WHERE e1.department = '技术部'
ORDER BY e1.id
LIMIT 100;
```

> 本案例无需额外 DDL，索引已在 schema 中定义，优化纯粹来自查询改写。

### 原理

移除 `IFNULL()` 函数包裹后，JOIN 条件变为 `e1.manager_id = e2.id`，优化器可以：

1. 驱动表 e1 通过 `idx_department` 定位"技术部"约 1 万名员工
2. 对每个员工的 `manager_id`，直接去 e2 表走**主键 eq_ref 查找**
3. 主键等值查找每次精确返回 1 行，O(1) 复杂度
4. 总查找次数：1 万 × 1 = 1 万次主键查找（vs bad 方案接近 1 亿次行检查）

`manager_id=0` 的行在 LEFT JOIN 时 e2 无匹配返回 NULL，语义与 bad 方案 `IFNULL(...,0)` 完全一致，但不破坏索引。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 耗时 | ~1250 ms | **~85 ms** |
| 被驱动表 type | ALL（全表扫描） | eq_ref（主键等值） |
| 被驱动表 rows/次 | ~99,680 | **1** |
| 被驱动表 Extra | Range checked for each record | NULL |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '99,680', Extra: 'Range checked for each record' }"
  :good="{ type: 'eq_ref', key: 'PRIMARY', rows: '1', Extra: 'NULL' }"
  improvement="被驱动表从全表扫描变为主键等值查找，行检查从 1 亿次降到 1 万次，耗时下降 15 倍"
/>

## 避坑指南

::: warning 注意事项

1. **JOIN 条件中不要对索引列施加函数**。常见的陷阱包括 `IFNULL`、`COALESCE`、`DATE_FORMAT`、`+ 0` 等。如需处理 NULL，可在应用层填充默认值，而非在 SQL 中用函数包裹索引列。

2. **自连接的索引和普通 JOIN 一样重要**。自连接本质是同一张表 JOIN 两次，优化关键完全一致：JOIN 条件列必须有可用索引。

3. **LEFT JOIN + NULL 语义**。用 `LEFT JOIN` 时，无匹配行返回 NULL，天然处理了"无上级"的情况，不需要 `IFNULL` 兜底。只有 SELECT 投影层需要非 NULL 值时才用 `IFNULL`。

4. **检查 EXPLAIN 的 Extra 列**。看到 `Range checked for each record` 要立即警惕--这意味着优化器无法提前确定使用哪个索引，正在逐行评估，通常是函数包裹或类型不匹配导致的。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 函数包裹导致索引失效 | ✅ 同样失效 | ✅ 同样失效 |
| 移除函数后的 eq_ref 优化 | ✅ 有效 | ✅ 有效 |
| 优化器索引选择 | 基础 | 更智能 |
| EXPLAIN ANALYZE | ❌ 不支持 | ✅ 支持行级执行统计 |

::: tip 8.0 EXPLAIN ANALYZE
8.0 支持 `EXPLAIN ANALYZE`，可以查看每个执行步骤的实际行数和耗时，对诊断自连接性能问题更有帮助。但函数包裹导致的索引失效在两个版本中都无法避免。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 37-self-join-optimization

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 37-self-join-optimization --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 37-self-join-optimization --no-seed
```
