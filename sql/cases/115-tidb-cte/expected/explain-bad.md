# EXPLAIN 参考结果 - bad.sql（不使用 CTE）

## TiDB v7.5.1（500 行树形结构 + 10 万行 cte_data）

---

### 场景1：自连接多层查询（无递归 CTE）

```sql
EXPLAIN SELECT t1.name AS l1, t2.name AS l2, t3.name AS l3
FROM t_tree t1
LEFT JOIN t_tree t2 ON t2.parent_id = t1.id
LEFT JOIN t_tree t3 ON t3.parent_id = t2.id
WHERE t1.parent_id IS NULL
LIMIT 20;
```

```
+--------------------------------+----------+-----------+------------------------------+----------------------------------------------+
| id                             | estRows  | task      | access object                | operator info                                |
+--------------------------------+----------+-----------+------------------------------+----------------------------------------------+
| Limit_16                       | 20.00    | root      |                              | offset:0, count:20                           |
| └─HashJoin_18                  | 20.00    | root      |                              | left outer join, equal:[eq(t_tree.parent_id, t_tree.id)] |
|   ├─HashJoin_20(Build)         | 20.00    | root      |                              | left outer join, equal:[eq(t_tree.parent_id, t_tree.id)] |
|   │ ├─IndexReader_25(Build)    | 1.00     | root      |                              | index:IndexRangeScan_24                      |
|   │ │ └─IndexRangeScan_24      | 1.00     | cop[tikv] | table:t1, index:idx_parent   | range:[NULL,NULL], keep order:false           |
|   │ └─TableReader_27(Probe)    | 500.00   | root      |                              | data:TableFullScan_26                        |
|   │   └─TableFullScan_26       | 500.00   | cop[tikv] | table:t2                     | keep order:false                             |
|   └─TableReader_23(Probe)      | 500.00   | root      |                              | data:TableFullScan_22                        |
|     └─TableFullScan_22         | 500.00   | cop[tikv] | table:t3                     | keep order:false                             |
+--------------------------------+----------+-----------+------------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `Limit_16` | 限制返回 20 行 |
| 连接方式 | `HashJoin` x2 | 两次 Hash Join，分别连接 t1-t2 和 t2-t3 |
| 根节点扫描 | `IndexRangeScan` 查 `parent_id IS NULL` | 只有 1 行（根节点） |
| t2 扫描 | `TableFullScan` 500 行 | 全表扫描参与 Join |
| t3 扫描 | `TableFullScan` 500 行 | 全表扫描参与 Join |
| 核心问题 | 3 层需要 2 次 JOIN + 2 次全表扫描 | 如果扩展到 10 层，需要 9 次 JOIN + 9 次全表扫描 |

#### 为什么慢

- **层数固定**：3 层写死 3 个 LEFT JOIN，查 10 层需要 10 个 JOIN，SQL 极其冗长
- **无法自适应**：如果数据有 15 层深度，SQL 只能查到前 10 层
- **每次 JOIN 都需要全表扫描**：500 行 x 500 行 x 500 行 = 1.25 亿行的理论 Join 空间

---

### 场景2：子查询重复计算 AVG

```sql
EXPLAIN SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data) * 2;
```

```
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
| id                               | estRows    | task      | access object           | operator info                          |
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
| Union_12                         | 200000.00  | root      |                         |                                        |
| ├─Selection_14                   | 33333.33   | root      |                         | gt(t_cte_data.val, Column#7)           |
| │ └─TableReader_16               | 100000.00  | root      |                         | data:TableFullScan_15                  |
| │   └─TableFullScan_15           | 100000.00  | cop[tikv] | table:t_cte_data        | keep order:false                       |
| └─Selection_18                   | 33333.33   | root      |                         | gt(t_cte_data.val, mul(Column#7, 2))   |
|   └─TableReader_20               | 100000.00  | root      |                         | data:TableFullScan_19                  |
|     └─TableFullScan_19           | 100000.00  | cop[tikv] | table:t_cte_data        | keep order:false                       |
+----------------------------------+------------+-----------+-------------------------+----------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| 扫描次数 | **2 次** `TableFullScan` | UNION ALL 的两个分支各做一次全表扫描 |
| AVG 计算 | 隐藏在两个子查询中 | 每个分支都要重新计算 AVG(val)，共 **2 次全表扫描 + 2 次 AVG 聚合** |
| 预估行数 | estRows 各 33333.33 | 约 1/3 数据大于平均值（均匀分布假设） |
| 核心问题 | 子查询重复执行 | `(SELECT AVG(val) FROM t_cte_data)` 被计算了 2 次 |

#### 为什么慢

子查询 `(SELECT AVG(val) FROM t_cte_data)` 在 bad.sql 中出现了 **两次**，每次执行都需要全表扫描 10 万行。如果更多分支引用 AVG，扫描次数线性增长。
