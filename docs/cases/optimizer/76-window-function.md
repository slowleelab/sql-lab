# 窗口函数替代相关子查询

<CaseMeta difficulty="⭐⭐" category="优化器与8.0新特性" versions="8.0" :tags="['窗口函数', 'ROW_NUMBER', '相关子查询', '8.0新特性']" />

## 10 万：产品需求是：查询每个部门薪资最高的员工
薪资表 `t_salary` 有 10 万员工、100 个部门（每部门约 1000 人）。产品需求是：查询每个部门薪资最高的员工。这个"每组取 Top 1"的需求极为常见，但传统写法用相关子查询，性能惨不忍睹。

```sql
-- 相关子查询：外层每行都触发一次子查询求 MAX(salary)
SELECT s.id, s.emp_name, s.dept, s.salary
FROM t_salary s
WHERE s.salary = (
    SELECT MAX(s2.salary)
    FROM t_salary s2
    WHERE s2.dept = s.dept
)
ORDER BY s.dept, s.salary DESC;
```

表上明明建了 `idx_dept_salary (dept, salary)` 索引，子查询也走索引了，但 10 万行外层扫描 + 10 万次子查询累积下来，耗时高达 **1350ms**，结果只有区区 100 行（每部门 1 人）。

::: warning 真实场景
"每组取 Top N"是业务中最高频的查询模式之一：每个部门薪资最高的员工、每个分类销量 Top 10 的商品、每个用户最近 5 条订单。传统相关子查询写法对每行外层数据执行一次内层聚合，数据量稍大就会因子查询执行次数爆炸而变慢。8.0 窗口函数是这类需求的标准解法。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 用相关子查询查每个部门薪资最高的员工
--
-- 原理:
--   对外层每行 s，执行子查询 SELECT MAX(salary) FROM t_salary s2 WHERE s2.dept = s.dept
--   若当前行薪资等于该部门最高薪资，则保留。
--
--   问题:
--   1. 相关子查询: 外层每一行都触发一次子查询
--   2. 10 万行 -> 约 10 万次子查询执行
--   3. 每次子查询都扫描该部门约 1000 行算 MAX，累计开销巨大
SELECT s.id, s.emp_name, s.dept, s.salary
FROM t_salary s
WHERE s.salary = (
    SELECT MAX(s2.salary)
    FROM t_salary s2
    WHERE s2.dept = s.dept
)
ORDER BY s.dept, s.salary DESC;
```

### EXPLAIN 结果

```
+----+--------------------+----------+------+------------------+------------------+---------+---------------------+--------+----------+-------------+
| id | select_type        | table    | type | possible_keys     | key              | key_len | ref                 | rows   | filtered | Extra       |
+----+--------------------+----------+------+------------------+------------------+---------+---------------------+--------+----------+-------------+
|  1 | PRIMARY            | s        | ALL  | NULL             | NULL             | NULL    | NULL                |  99876 |   100.00 | Using where |
|  2 | DEPENDENT SUBQUERY | s2       | ref  | idx_dept_salary  | idx_dept_salary  | 83      | sql_treasure.s.dept |   1003 |   100.00 | NULL        |
+----+--------------------+----------+------+------------------+------------------+---------+---------------------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type (id=1) | `PRIMARY` | 外层全表扫描 s |
| type (id=1) | **`ALL`** | **全表扫描**，10 万行逐行处理 |
| rows (id=1) | ~99,876 | 扫描全部 10 万行 |
| select_type (id=2) | **`DEPENDENT SUBQUERY`** | **相关子查询！** 依赖外层每行 |
| type (id=2) | `ref` | 子查询走 idx_dept_salary 索引 |
| rows (id=2) | ~1,003 | 每次子查询扫描该部门约 1000 行算 MAX |

### 为什么慢

相关子查询是性能杀手，执行流程：

1. **外层全表扫描**：s 逐行扫描全部 10 万行（type=ALL，无索引可用）
2. **逐行触发子查询**：对 s 的**每一行**，执行一次子查询
3. **子查询求 MAX**：`SELECT MAX(salary) FROM t_salary s2 WHERE s2.dept = s.dept`
4. **过滤判断**：若当前行薪资等于该部门最高薪资，则保留

关键开销：
- 外层 10 万行 x 每行 1 次子查询 = **约 10 万次子查询执行**
- 每次子查询走索引扫描约 1000 行算 MAX = 累计约 **1 亿次索引行读取**
- 虽然单次子查询走索引较快，但 10 万次的累积开销巨大

相关子查询的本质是"嵌套循环"，无法批量化处理。N 行外层数据 = N 次内层执行，复杂度 O(N*M)。

::: warning 相关子查询的性能陷阱
`WHERE col = (SELECT MAX(col) ... WHERE ... = outer.col)` 是典型的"每组取 Top 1"反模式。它对每行外层数据执行一次内层聚合查询，数据量稍大就会因子查询执行次数爆炸而变慢。这类需求应优先用窗口函数改写。
:::

::: tip 核心认知
相关子查询的本质是嵌套循环--N 行外层触发 N 次内层执行，复杂度 O(N*M)。窗口函数将其降为单次扫描 + 分组排序，复杂度 O(N log N)。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 用 ROW_NUMBER() 窗口函数查每个部门薪资最高的员工
--
-- 原理:
--   ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC)
--   按 dept 分组，组内按 salary 降序编号 1,2,3...
--   外层过滤 rn = 1 即取每部门薪资最高的员工。
--
--   优势:
--   - 单次扫描完成分组排序，无需相关子查询
--   - 优化器可利用 idx_dept_salary (dept, salary) 索引有序性
--   - 逻辑清晰，性能稳定
SELECT id, emp_name, dept, salary
FROM (
    SELECT id, emp_name, dept, salary,
           ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn
    FROM t_salary
) ranked
WHERE rn = 1
ORDER BY dept;
```

### 原理

窗口函数将"每部门取最高薪资"转化为单次扫描 + 分组编号：

1. **单次索引扫描**：内层查询走 `idx_dept_salary` 索引全扫描（type=index）
2. **覆盖索引**：dept、salary、id 都在索引中（联合索引 + 主键），`Using index` 不回表
3. **索引有序**：idx_dept_salary 已按 (dept, salary) 排序，窗口函数直接利用此顺序分区编号
4. **ROW_NUMBER 编号**：按 dept 分区、salary DESC 编号 1,2,3...
5. **外层过滤**：从派生表取 rn = 1 的行（每部门薪资最高的）

对比 bad 方案：
- bad：10 万次相关子查询，每次扫约 1000 行 = 累计约 1 亿次索引行读取
- good：**1 次**索引全扫描，覆盖索引不回表 = 10 万次索引顺序读

窗口函数消除了嵌套循环，将 O(N*M) 降为 O(N log N)（排序分区）。且因索引已有序，排序开销也被优化器消除。

### 对比

| | bad.sql (相关子查询) | good.sql (窗口函数) |
|---|---|---|
| 外层 type | ALL（全表扫描） | index（索引扫描） |
| 子查询执行次数 | ~100,000 | **0** |
| 索引行读取 | ~100,000,000 | ~99,876（顺序读） |
| 回表 | 是（子查询回表） | **否（覆盖索引）** |
| 耗时 | ~1350 ms | **~70 ms** |

<ExplainCompare
  :bad="{ type: 'ALL + DEPENDENT SUBQUERY', key: 'NULL + idx_dept_salary', rows: '99,876 × 1,003', Extra: 'Using where' }"
  :good="{ type: 'index（覆盖索引）', key: 'idx_dept_salary', rows: '99,876（单次）', Extra: 'Using index' }"
  improvement="子查询执行次数从 10 万降到 0，索引行读取减少 99.9%，耗时下降约 19 倍"
/>

## 避坑指南

::: warning 注意事项

1. **窗口函数需要 8.0+**。`ROW_NUMBER() OVER (...)` 是 8.0 才支持的语法。5.7 中只能用相关子查询、自连接或存储过程，性能和可读性都差。升级到 8.0 后应优先用窗口函数改写这类"每组取 Top N"的查询。

2. **覆盖索引是关键加成**。本例能走 `Using index` 是因为 `idx_dept_salary (dept, salary)` 覆盖了窗口函数所需的列，加上主键 id 也在索引中。如果窗口函数引用了索引外的列（如 emp_name），仍需回表，性能会打折扣。

3. **ROW_NUMBER vs RANK vs DENSE_RANK**。`ROW_NUMBER()` 无并列排名（同薪资随机取一个），适合取每组 Top N。如果业务要求并列也都要取，用 `RANK()` 或 `DENSE_RANK()`，过滤条件改为 `WHERE rn = 1` 仍能取到所有并列第一。

4. **子查询过滤 rn 必须包在外层**。窗口函数不能直接出现在 WHERE 子句中，必须先在子查询中计算 `ROW_NUMBER()`，再在外层用 `WHERE rn = 1` 过滤。这是 SQL 语法限制，不是性能问题。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 窗口函数 `OVER ()` | ❌ 不支持 | ✅ 原生支持 |
| `ROW_NUMBER()` / `RANK()` / `DENSE_RANK()` | ❌ 不支持 | ✅ 支持 |
| `LAG()` / `LEAD()` | ❌ 不支持 | ✅ 支持 |
| "每组取 Top N"推荐写法 | 相关子查询 / 自连接 / 存储过程 | ✅ 窗口函数（简洁高效） |

::: tip 8.0 窗口函数
8.0 的窗口函数是最实用的新特性之一。`ROW_NUMBER()` 取每组 Top N、`LAG()/LEAD()` 取前后行做环比同比、`SUM() OVER()` 做累计求和--这些 5.7 时代只能用相关子查询或存储过程实现的需求，8.0 一条 SQL 搞定，性能和可读性都大幅提升。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 76-window-function

# 跳过造数据重跑
./scripts/run-case.sh 76-window-function --no-seed
```
