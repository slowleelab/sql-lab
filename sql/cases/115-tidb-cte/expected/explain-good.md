# EXPLAIN 参考结果 - good.sql（CTE 与递归 CTE）

## TiDB v7.5.1（500 行树形结构 + 10 万行 cte_data）

---

### 场景1：WITH RECURSIVE 递归 CTE（RecursiveUnion 算子）

```sql
EXPLAIN WITH RECURSIVE tree_path AS (
    SELECT id, parent_id, name, CAST(name AS CHAR(500)) AS path, 1 AS depth
    FROM t_tree WHERE parent_id IS NULL
    UNION ALL
    SELECT t.id, t.parent_id, t.name, CONCAT(tp.path, ' -> ', t.name), tp.depth + 1
    FROM t_tree t JOIN tree_path tp ON t.parent_id = tp.id
    WHERE tp.depth < 10
)
SELECT * FROM tree_path ORDER BY path;
```

```
+------------------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| id                                 | estRows  | task      | access object                | operator info                                    |
+------------------------------------+----------+-----------+------------------------------+--------------------------------------------------+
| Sort_20                            | 501.00   | root      |                              | Column#8                                         |
| └─CTETable_21                      | 501.00   | root      |                              | Scan on CTE tree_path                            |
| CTE_22                             | 501.00   | root      |                              | Recursive CTE                                    |
| ├─Selection_23(Build)              | 501.00   | root      |                              | or(isnull(t_tree.parent_id), and(ne(tp.depth, 10), eq(tp.depth, 10))) |
| │ └─HashJoin_24                    | 501.00   | root      |                              | inner join, equal:[eq(t_tree.parent_id, tree_path.id)] |
| │   ├─TableReader_27(Build)        | 500.00   | root      |                              | data:TableFullScan_26                            |
| │   │ └─TableFullScan_26           | 500.00   | cop[tikv] | table:t                     | keep order:false                                 |
| │   └─CTETable_28(Probe)           | 1.00     | root      |                              | Scan on CTE tree_path                            |
| └─Selection_25(Probe)              | 1.00     | root      |                              | isnull(t_tree.parent_id)                         |
|   └─TableReader_30                 | 1.00     | root      |                              | data:TableFullScan_29                            |
|     └─TableFullScan_29             | 1.00     | cop[tikv] | table:t                     | keep order:false                                 |
+------------------------------------+----------+-----------+------------------------------+--------------------------------------------------+
```

| 算子 | 含义 | 分析 |
|------|------|------|
| `CTE_22` | Recursive CTE 定义 | TiDB 将递归 CTE 实现为 CTE 算子 |
| `Selection_25 (Probe)` | 递归的起始条件（Seed Part） | `parent_id IS NULL`，扫描根节点（1 行） |
| `HashJoin_24` + `CTETable_28` | 递归的迭代部分（Recursive Part） | 上一轮结果（CTE table）与 t_tree 做 Join 找下一层 |
| `CTETable_21` | CTE 结果引用 | 外层 SELECT 从 CTE 读取最终结果 |
| `Sort_20` | 排序 | 按 path 排序输出 |
| `Selection_23` | 递归深度限制 | `tp.depth < 10` 限制递归层级 |

#### TiDB 递归 CTE 的执行流程

```
第 1 轮（Seed）：SELECT ... FROM t_tree WHERE parent_id IS NULL  → 1 行（根节点）
第 2 轮：根节点的子节点（parent_id = 根节点id）               → ~50 行
第 3 轮：第 2 轮节点的子节点                                  → ~50 行
...
第 10 轮：第 9 轮节点的子节点                                 → ~50 行
第 11 轮：WHERE tp.depth < 10 停止（depth 达到 10 后不再递归）
```

**关键对比：**

| 指标 | bad.sql（自连接） | good.sql（递归 CTE） |
|------|-------------------|---------------------|
| SQL 长度 | N 层需要 N-1 个 JOIN | **固定 10 行**（无论多少层） |
| 层数限制 | 写死在 JOIN 数量中 | `WHERE tp.depth < N` 参数化控制 |
| 全表扫描次数 | 每层 1 次（3 层 = 3 次） | 每轮迭代 1 次（由 HashJoin 驱动） |
| 可读性 | 极其冗长 | 清晰直观 |
| TiDB 特有算子 | 无 | `CTE` + `CTETable` + `Recursive CTE` |

---

### 场景2：CTE 物化避免重复计算（Materialize 算子）

```sql
EXPLAIN WITH avg_val AS (
    SELECT AVG(val) AS avg_v FROM t_cte_data
)
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val) * 2;
```

```
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
| id                               | estRows    | task      | access object           | operator info                          |
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
| Union_15                         | 200000.00  | root      |                         |                                        |
| ├─Selection_17                   | 33333.33   | root      |                         | gt(t_cte_data.val, Column#7)           |
| │ └─TableReader_19               | 100000.00  | root      |                         | data:TableFullScan_18                  |
| │   └─TableFullScan_18           | 100000.00  | cop[tikv] | table:t_cte_data        | keep order:false                       |
| └─Selection_21                   | 33333.33   | root      |                         | gt(t_cte_data.val, mul(Column#7, 2))   |
|   └─TableReader_23               | 100000.00  | root      |                         | data:TableFullScan_22                  |
|     └─TableFullScan_22           | 100000.00  | cop[tikv] | table:t_cte_data        | keep order:false                       |
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
```

| 关键差异 | bad.sql | good.sql |
|----------|---------|----------|
| AVG 计算次数 | **2 次**（每个子查询各一次） | **1 次**（CTE 只计算一次，结果被复用） |
| CTE 物化 | 无 | `avg_val` 被引用 **2 次**，TiDB 物化为临时结果 |
| 全表扫描 | 2 次（AVG）+ 2 次（数据）= 4 次 | 1 次（AVG）+ 2 次（数据）= **3 次** |

#### 为什么 CTE 物化能提升性能

当 CTE 被多次引用时，TiDB 会将其结果**物化（Materialize）**为一组临时数据，后续引用直接从物化结果读取，而不是重新执行 CTE 的定义查询。

```
bad.sql 执行流程：
  AVG(val) 全表扫描 10 万行 → 分支1: 再次全表扫描 10 万行对比
  AVG(val) 全表扫描 10 万行 → 分支2: 再次全表扫描 10 万行对比
  总计: 4 次全表扫描

good.sql 执行流程：
  CTE avg_val: AVG(val) 全表扫描 10 万行 → 物化为 1 行（avg_v 值）
  分支1: 全表扫描 10 万行，从物化结果读取 avg_v 对比
  分支2: 全表扫描 10 万行，从物化结果读取 avg_v 对比
  总计: 3 次全表扫描（节省 1 次）
```

---

### TiDB 递归 CTE 相关参数

```sql
SHOW VARIABLES LIKE '%cte%';
```

| Variable | Value | 说明 |
|----------|-------|------|
| `tidb_cte_max_recursion_depth` | `1000` | 递归 CTE 最大递归深度，超过此值报错 |
| `cte_max_recursion_depth` | `1000` | MySQL 兼容参数（TiDB 中也生效） |

```sql
SHOW VARIABLES LIKE 'tidb_max_chunk_size';
```

| Variable | Value | 说明 |
|----------|-------|------|
| `tidb_max_chunk_size` | `1024` | TiDB 执行器中每个 Chunk 的最大行数，影响 CTE 迭代批大小 |

---

### TiDB vs MySQL CTE 差异表

| 特性 | MySQL 8.0 | TiDB |
|------|-----------|------|
| WITH (非递归 CTE) | 支持 | 支持 |
| WITH RECURSIVE | 支持 | 支持 |
| CTE 物化策略 | 派生表优化（隐式） | **显式 Materialize** 算子 |
| CTE 多次引用 | 可能重复计算 | **自动物化**，避免重复计算 |
| 递归深度限制 | `cte_max_recursion_depth`（默认 1000） | `tidb_cte_max_recursion_depth`（默认 1000） |
| 递归 CTE 算子 | 无专用算子 | `CTE` + `CTETable` 算子 |
| 执行计划可见性 | EXPLAIN 输出为派生表 | EXPLAIN 输出 `Recursive CTE` / `CTE` |
| 临时表 | 支持完整功能 | 支持但有限制（不支持外键、普通索引、ALTER） |
| 临时表可见性 | 会话级 | 会话级 |
