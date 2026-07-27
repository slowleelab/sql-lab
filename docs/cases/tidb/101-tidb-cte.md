# TiDB CTE 与临时表优化

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['CTE', 'WITH RECURSIVE', '临时表', 'Materialize', '递归查询']" />

## 场景痛点

你负责维护公司的组织架构系统，需要支持"查看某个员工的所有下属（任意层级）"。在 MySQL 5.7 时代，你的做法是写死 N 层 LEFT JOIN：

```sql
SELECT t1.name AS l1, t2.name AS l2, t3.name AS l3, t4.name AS l4, t5.name AS l5
FROM t_employee t1
LEFT JOIN t_employee t2 ON t2.manager_id = t1.id
LEFT JOIN t_employee t3 ON t3.manager_id = t2.id
LEFT JOIN t_employee t4 ON t4.manager_id = t3.id
LEFT JOIN t_employee t5 ON t5.manager_id = t4.id
WHERE t1.manager_id IS NULL;
```

然后有一天 CEO 问："咱们公司最深几级汇报关系？"

你沉默了——因为你的 SQL 最多写到了 5 层。

后来公司上了 TiDB，听说支持 WITH RECURSIVE。你满怀期待地把 MySQL 8.0 的递归 CTE 写法搬过来，却发现 TiDB 的执行计划里多了一个叫 `CTE` 的算子和 `CTETable` 的东西，而且 EXPLAIN 输出跟 MySQL 完全不同。

更让你困惑的是：同事写了一个报表 SQL，把 `AVG()` 放在 CTE 里，结果发现 TiDB 只在第一次引用时计算一次，后续引用直接复用——但 MySQL 8.0 在 EXPLAIN 里看起来却像是重新算了一遍。

::: warning 真实场景
TiDB 的 CTE 实现与 MySQL 8.0 有本质差异：TiDB 内置 **CTE 物化（Materialize）** 策略，当 CTE 被多次引用时，自动将结果缓存为临时数据集。这既是优点（避免重复计算），也是需要注意的点（占用内存）。此外 TiDB 临时表的功能集也与 MySQL 不同——不支持外键、不支持普通索引、不支持 ALTER TABLE。
:::

## 问题分析

### bad.sql：不使用 CTE 的两种反模式

**反模式一：多层自连接查树形结构**

```sql
SELECT t1.name AS l1, t2.name AS l2, t3.name AS l3
FROM t_tree t1
LEFT JOIN t_tree t2 ON t2.parent_id = t1.id
LEFT JOIN t_tree t3 ON t3.parent_id = t2.id
WHERE t1.parent_id IS NULL
LIMIT 20;
```

每增加一层深度，就需要多一个 LEFT JOIN。10 层的组织架构需要 9 次 JOIN——SQL 长度随层级线性增长，且层数写死在代码中，数据深度变化时 SQL 无法自适应。

**反模式二：子查询重复计算聚合值**

```sql
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data) * 2;
```

`(SELECT AVG(val) FROM t_cte_data)` 被写了两遍——数据库也就老老实实算了两遍。每次 AVG 计算 = 全表扫描 10 万行。你有 N 个分支，它就扫描 N 次。

### EXPLAIN 分析：自连接的代价

```
Limit_16 (root)
└─HashJoin_18 (root)          ← t1 LEFT JOIN t2
  ├─HashJoin_20 (root)        ← t1 LEFT JOIN t3
  │ ├─IndexRangeScan (root)   ← 根节点（parent_id IS NULL）
  │ └─TableFullScan (t2)      ← 全表扫描 500 行
  └─TableFullScan (t3)        ← 全表扫描 500 行
```

- 3 层 = 2 次 HashJoin + 2 次全表扫描
- 扩展到 10 层 = 9 次 HashJoin + 9 次全表扫描
- 没有任何 TiDB 特有的 CTE 算子——这纯粹是 MySQL 5.7 时代的写法

### EXPLAIN 分析：子查询重复扫描

UNION ALL 的两个分支各自包含独立的子查询 `(SELECT AVG(val) ...)`，优化器无法自动识别它们是同一个值。结果就是 **2 次全表扫描求 AVG + 2 次全表扫描做过滤 = 4 次全表扫描**。

## 优化方案

### good.sql：WITH RECURSIVE + CTE 物化

**优化一：递归 CTE 一条语句遍历整棵树**

```sql
WITH RECURSIVE tree_path AS (
    -- Seed: 根节点
    SELECT id, parent_id, name, CAST(name AS CHAR(500)) AS path, 1 AS depth
    FROM t_tree WHERE parent_id IS NULL
    UNION ALL
    -- Recursive: 找下一层子节点
    SELECT t.id, t.parent_id, t.name,
           CONCAT(tp.path, ' -> ', t.name), tp.depth + 1
    FROM t_tree t JOIN tree_path tp ON t.parent_id = tp.id
    WHERE tp.depth < 10
)
SELECT * FROM tree_path ORDER BY path;
```

**执行流程：**

```
第 1 轮（Seed）： 找到根节点（1 行）
第 2 轮：根的子节点（~50 行）
第 3 轮：第 2 轮节点的子节点（~50 行）
...
第 10 轮：第 9 轮节点的子节点（~50 行）
第 11 轮：WHERE tp.depth < 10 → 停止
```

TiDB 的 EXPLAIN 中会显示 `CTE_xx` 算子（`Recursive CTE`），以及 `CTETable_xx` 算子（从 CTE 结果中读取数据）。

**优化二：CTE 物化避免重复计算**

```sql
WITH avg_val AS (
    SELECT AVG(val) AS avg_v FROM t_cte_data
)
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val) * 2;
```

`avg_val` CTE 被两个分支各引用一次。TiDB 检测到 CTE 被多次引用后，自动物化其结果（1 行，一个 AVG 值），后续引用直接从内存读取，不再重复执行 CTE 定义。

### TiDB 递归 CTE 的核心算子

| 算子 | 出现场景 | 含义 |
|------|---------|------|
| `CTE_xx` | 递归 CTE 定义 | 完整的 CTE 定义，包含 Seed Part 和 Recursive Part |
| `CTETable_xx` | 引用 CTE 结果 | 从 CTE 物化结果中扫描数据 |
| `Recursive CTE` | operator info | 标记这是一个递归 CTE |

### 临时表在 TiDB 中的使用

```sql
-- 创建临时表（会话级别，连接断开自动删除）
CREATE TEMPORARY TABLE temp_high_val AS
SELECT * FROM t_cte_data WHERE val > 8000;

-- 基于临时表做后续查询
SELECT COUNT(*) FROM temp_high_val;
```

**TiDB 临时表与 MySQL 临时表的关键差异：**

| 特性 | MySQL 8.0 | TiDB |
|------|-----------|------|
| 创建临时表 | 支持 | 支持 |
| ALTER TABLE | 支持 | **不支持** |
| 外键 | 不支持（临时表本身不支持） | 不支持 |
| 普通索引 | 支持 | **不支持**（仅支持主键） |
| 可见性 | 会话级 | 会话级 |
| 事务行为 | 不受事务回滚影响 | 不受事务回滚影响 |
| 与永久表同名 | 临时表优先 | 临时表优先 |

### bad vs good 量化对比

| 指标 | bad.sql（无 CTE） | good.sql（CTE） | 提升 |
|------|-------------------|-----------------|------|
| 树查询 SQL 行数 | 3 层 = 6 行，10 层 = 20 行 | **固定 10 行** | N/A |
| 层数灵活性 | 写死在 JOIN 中 | `WHERE depth < N` 参数化 | 任意深度 |
| AVG 全表扫描 | 4 次 | 3 次 | **减少 25%** |
| CTE 被多次引用 | 无 CTE，每次重复计算 | 物化 1 次，复用 N 次 | **O(N) -> O(1)** |
| 递归深度控制 | 无法控制 | `tidb_cte_max_recursion_depth` | 安全兜底 |

<ExplainCompare
  :bad="{ sql_length: '层级 × N', avg_scans: '4次全表扫描', recursion: '不支持' }"
  :good="{ sql_length: '固定10行', avg_scans: '3次全表扫描', recursion: 'WITH RECURSIVE 一条语句' }"
  improvement="CTE 物化减少重复计算，递归 CTE 简化树形查询，SQL 更简洁且自适应任意层级"
/>

## 避坑指南

::: warning TiDB CTE 使用注意事项

1. **CTE 物化占用内存**。当 CTE 被多次引用时，TiDB 会将其结果物化到内存中。如果 CTE 结果集很大（百万行级别），物化可能占用大量内存甚至触发 OOM。建议对大数据量的 CTE 使用 `LIMIT` 限制结果集大小。

2. **递归深度有硬限制**。`tidb_cte_max_recursion_depth` 默认 1000，超过后会报错 `Query execution was interrupted, max recursion depth is reached`。如果你的组织架构真的超过 1000 层——你的组织架构可能有问题。

3. **递归 CTE 不支持聚合和 DISTINCT**。TiDB 的递归部分（UNION ALL 之后的 SELECT）不能包含 `GROUP BY`、`DISTINCT`、`ORDER BY`、`LIMIT` 和聚合函数。这与 MySQL 8.0 限制一致。

4. **临时表不支持普通索引**。TiDB 临时表只能有主键，不能创建普通二级索引。如果临时表数据量较大且需要按非主键列查询，建议在插入前对源表先做过滤。

5. **临时表不支持 ALTER TABLE**。创建后无法修改表结构。需要在 CREATE TEMPORARY TABLE 时一步定义好所有列。

6. **CTE 与临时表选择**。CTE 适合单条 SQL 内复用中间结果（物化自动管理），临时表适合跨多条 SQL 复用（会话内保持）。CTE 的生命周期是单条 SQL，临时表的生命周期是整个会话。

7. **MySQL 8.0 的 CTE 迁移到 TiDB**。大多数 CTE 语法可以直接迁移，但要注意 TiDB 中 `EXPLAIN` 输出格式不同（多了 CTE 相关算子），且递归深度的参数名不同（`tidb_cte_max_recursion_depth` vs `cte_max_recursion_depth`）。

8. **不要假设 CTE 一定物化**。TiDB 优化器会根据代价模型决定是否物化。如果 CTE 只被引用一次，优化器可能选择不物化，直接展开为内联子查询。可以通过 `EXPLAIN` 确认实际的执行策略。
:::

### TiDB vs MySQL CTE 差异表

| 特性 | MySQL 8.0 | TiDB | 说明 |
|------|-----------|------|------|
| WITH (非递归) | 支持 | 支持 | 语法完全兼容 |
| WITH RECURSIVE | 支持 | 支持 | 语法完全兼容 |
| CTE 物化 | 派生表优化（隐式） | **显式 Materialize** 策略 | TiDB 在多次引用时自动物化 |
| CTE 单次引用 | 展开为内联 | 通常展开（不物化） | 行为一致 |
| CTE 多次引用 | 可能重复计算 | **自动物化**，复用结果 | TiDB 更优 |
| 递归深度参数 | `cte_max_recursion_depth` | `tidb_cte_max_recursion_depth` | 参数名不同，默认值均为 1000 |
| 递归 CTE 执行计划 | EXPLAIN 输出为派生表 | `CTE` + `CTETable` + `Recursive CTE` | TiDB 算子更直观 |
| EXPLAIN FORMAT | TREE/JSON | row/verbose/dot | 格式不同 |
| 临时表 ALTER | 支持 | **不支持** | TiDB 的限制 |
| 临时表普通索引 | 支持 | **不支持**（仅主键） | TiDB 的限制 |
| 临时表外键 | 不支持 | 不支持 | 一致 |

## 本地复现

```bash
./scripts/run-case.sh 101-tidb-cte --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```

然后连接到 TiDB 执行：

```sql
-- 对比 bad.sql 和 good.sql 的执行计划差异
source sql/cases/101-tidb-cte/schema.sql;
source sql/cases/101-tidb-cte/seed.sql;

-- 查看递归 CTE 执行计划（重点关注 CTE 和 CTETable 算子）
EXPLAIN WITH RECURSIVE tree_path AS (
    SELECT id, parent_id, name, CAST(name AS CHAR(500)) AS path, 1 AS depth
    FROM t_tree WHERE parent_id IS NULL
    UNION ALL
    SELECT t.id, t.parent_id, t.name,
           CONCAT(tp.path, ' -> ', t.name), tp.depth + 1
    FROM t_tree t JOIN tree_path tp ON t.parent_id = tp.id
    WHERE tp.depth < 10
)
SELECT * FROM tree_path ORDER BY path;

-- 调整递归深度限制
SET SESSION tidb_cte_max_recursion_depth = 100;
SHOW VARIABLES LIKE '%cte%';
```
:::
