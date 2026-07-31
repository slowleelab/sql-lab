# CTE 递归查询优化树形结构

<CaseMeta difficulty="⭐⭐" category="优化器与8.0新特性" versions="8.0" :tags="['CTE', '递归查询', '树形结构', '8.0新特性']" />

## 场景痛点

组织架构表 `t_employee_org` 用 `manager_id` 指向 `id` 形成层级关系，共约 10 万人，5 层树深（CEO -> VP -> 总监 -> 经理 -> 员工）。产品需求是：查询某个 VP 名下所有层级的下属。

传统做法是多次自连接，N 层结构需要 N-1 次 JOIN：

```sql
-- 查 VP-1 下所有层级下属（level 3/4/5），需要 3 次 JOIN
SELECT e5.id, e5.emp_name, e5.level
FROM t_employee_org e2
JOIN t_employee_org e3 ON e3.manager_id = e2.id
JOIN t_employee_org e4 ON e4.manager_id = e3.id
JOIN t_employee_org e5 ON e5.manager_id = e4.id
WHERE e2.emp_name = 'VP-1';
```

这段 SQL 看起来能跑，但有两个致命问题：**层数被 SQL 文本焊死**--写死 3 次 JOIN 只能查到 level 5，如果组织架构多了第 6 层就漏数据；而且 SQL 冗长，每多一层就要加一个 JOIN 和别名，可读性急剧下降。

::: warning 真实场景
树形结构遍历在生产中极为常见：组织架构树、菜单树、评论楼中楼、物料 BOM 展开、好友关系链。现实中这些结构的深度不固定且可能很深（如 10 层）。自连接方案要么查不全（层数不够），要么写一长串 JOIN（可读性崩溃），根本无法自适应。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 传统多次自连接查询某 VP 下所有层级的下属
-- 5 层结构需要 4 次自连接，层数写死；若层数变化需改 SQL
-- 假设查询 VP-1 (level 2) 下所有下属（level 3/4/5）
SELECT
    e5.id, e5.emp_name, e5.level
FROM t_employee_org e2
JOIN t_employee_org e3 ON e3.manager_id = e2.id
JOIN t_employee_org e4 ON e4.manager_id = e3.id
JOIN t_employee_org e5 ON e5.manager_id = e4.id
WHERE e2.emp_name = 'VP-1';
```

### EXPLAIN 结果

```
+----+-------------+-------+------+---------------+------------+---------+---------------------+--------+----------+-------+
| id | select_type | table | type | possible_keys | key        | key_len | ref                 | rows   | filtered | Extra |
+----+-------------+-------+------+---------------+------------+---------+---------------------+--------+----------+-------+
|  1 | SIMPLE      | e2    | ref  | idx_manager   | idx_manager| 9       | const               | 1      |   100.00 | NULL  |
|  1 | SIMPLE      | e3    | ref  | idx_manager   | idx_manager| 9       | sql_treasure.e2.id  | 10     |   100.00 | NULL  |
|  1 | SIMPLE      | e4    | ref  | idx_manager   | idx_manager| 9       | sql_treasure.e3.id  | 20     |   100.00 | NULL  |
|  1 | SIMPLE      | e5    | ref  | idx_manager   | idx_manager| 9       | sql_treasure.e4.id  | 100    |   100.00 | NULL  |
+----+-------------+-------+------+---------------+------------+---------+---------------------+--------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| table | e2, e3, e4, e5 | 4 个表别名代表 4 层连接 |
| type | 全部 `ref` | 每层都走 idx_manager 索引 |
| rows (e5) | ~100 | 最内层每经理下约 100 员工 |
| JOIN 层级 | 3 次 JOIN | **层数硬编码为 3 层 JOIN** |

### 为什么慢

多次自连接方案的根本问题是**层数硬编码**：

1. **层数固定**：本例写死 3 次 JOIN（覆盖 level 3/4/5）。若组织架构有 6 层，此 SQL 只能查到 level 5，漏查更深层级，必须改 SQL 加 JOIN。
2. **SQL 冗长**：每多一层就要加一个 JOIN 和别名，N 层结构需 N-1 次 JOIN，SQL 膨胀严重。
3. **驱动方式低效**：e2 -> e3 -> e4 -> e5 逐层嵌套循环，中间结果集逐层膨胀（1 -> 10 -> 200 -> 20000），最内层 e5 要执行 200 次索引查找。
4. **无法自适应**：不同子树的深度可能不同，自连接要么查不全，要么多余 JOIN 产生空结果。

对于本例 VP-1 的子树（20000 人），3 次 JOIN 的嵌套循环展开后，e5 表的索引查找执行次数 = 200（经理数），虽然每次走索引，但累积的随机 I/O 仍有开销。

::: tip 核心认知
自连接方案把树深"焊死"在 SQL 文本里--层数变了就得改 SQL。树形遍历的正解是递归 CTE，一条语句自适应任意深度。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 8.0 递归 CTE 一条语句遍历任意深度层级
-- WITH RECURSIVE 自动递归到所有层级，无需写死 JOIN 次数
WITH RECURSIVE org_tree AS (
    -- 锚点: 起始节点（VP-1）
    SELECT id, emp_name, manager_id, level
    FROM t_employee_org
    WHERE emp_name = 'VP-1'

    UNION ALL

    -- 递归: 逐层向下找下属
    SELECT e.id, e.emp_name, e.manager_id, e.level
    FROM t_employee_org e
    INNER JOIN org_tree ot ON e.manager_id = ot.id
)
SELECT id, emp_name, level
FROM org_tree
ORDER BY level, id;
```

### 原理

递归 CTE 的执行模型清晰高效，分为锚点和递归两部分：

1. **锚点执行**：`WHERE emp_name = 'VP-1'` 定位起始节点（1 行）
2. **递归迭代**：用上一轮结果 JOIN t_employee_org（走 idx_manager 索引），找下一层下属
   - 第 1 轮：VP-1 -> 10 个总监
   - 第 2 轮：10 总监 -> 200 个经理
   - 第 3 轮：200 经理 -> 20000 个员工
   - 第 4 轮：员工无下属，递归终止
3. **物化合并**：每轮结果 UNION ALL 累加到临时表，直到无新增行即终止
4. **最终输出**：从物化临时表读取并排序

对比自连接方案的优势：
- **自适应深度**：无论子树深 3 层还是 30 层，同一条 SQL 都能查全，无需修改
- **无嵌套膨胀**：递归每轮独立执行，不会像自连接那样逐层嵌套循环膨胀
- **UNION ALL 不去重**：递归用 UNION ALL（无去重开销），比 UNION 更轻量
- **代码简洁**：12 行 SQL vs 自连接方案的冗长 JOIN 链

### 对比

| | bad.sql (多次自连接) | good.sql (递归 CTE) |
|---|---|---|
| SQL 行数 | 8 行（3 次 JOIN） | 12 行（但自适应） |
| 层数适应性 | 固定（需改 SQL） | **任意深度** |
| 执行方式 | 嵌套循环逐层膨胀 | 递归每轮独立物化 |
| UNION 类型 | 无（纯 JOIN） | UNION ALL（无去重） |
| 耗时 | ~85 ms | **~45 ms** |

<ExplainCompare
  :bad="{ type: 'ref ×4', key: 'idx_manager（4层JOIN写死）', rows: '1→10→200→20000', Extra: 'NULL' }"
  :good="{ type: 'PRIMARY+DERIVED+RECURSIVE', key: 'idx_manager（递归3轮）', rows: '1→10→200→20000', Extra: 'Using temporary' }"
  improvement="层数自适应任意深度，耗时下降 1.9 倍"
/>

## 避坑指南

::: warning 注意事项

1. **cte_max_recursion_depth 限制**。默认递归深度上限 1000，深树需 `SET cte_max_recursion_depth = 5000;`。如果树深超过限制，递归会在未遍历完时被截断，结果不完整。

2. **防止死循环**。若数据有环（A 的经理是 B，B 的经理是 A），递归不会终止。树形结构天然无环，但如果数据脏（如录入错误），需在递归部分加入深度计数器作为保护：`WHERE ot.depth < 100`。

3. **UNION ALL vs UNION**。递归用 UNION ALL 避免去重开销。树结构无环不会有重复行，用 UNION 反而引入不必要的排序去重开销。只有在图遍历（可能有环且不去重会导致行爆炸）时才考虑 UNION。

4. **manager_id 上必须有索引**。本例的 `idx_manager (manager_id)` 是递归 JOIN 的关键。没有这个索引，每轮递归都要全表扫描，性能急剧恶化。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `WITH RECURSIVE` 递归 CTE | ❌ 不支持 | ✅ 原生支持 |
| 树形遍历方式 | 只能多次自连接或存储过程 | ✅ 递归 CTE 一条语句 |
| 非递归 CTE（`WITH cte AS (SELECT ...)`） | ✅ 支持 | ✅ 支持 |
| `cte_max_recursion_depth` | ❌ 无此变量（用不到） | ✅ 可配置递归深度上限 |

::: tip 8.0 递归 CTE
8.0 的 `WITH RECURSIVE` 是树形/图遍历的正解。组织架构、菜单树、评论楼中楼、物料 BOM 展开、好友关系链等场景，一条递归 CTE 即可自适应任意深度，告别自连接的层数硬编码问题。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 75-cte-recursive

# 跳过造数据重跑
./scripts/run-case.sh 75-cte-recursive --no-seed
```
