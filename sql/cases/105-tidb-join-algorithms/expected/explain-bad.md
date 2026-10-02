# EXPLAIN 参考结果 - bad.sql（非最优 Join 算法场景）

## TiDB（t_join_a 10 万行 + t_join_b 5 万行 + t_join_c 500 行）

---

### 场景1: 大表 JOIN 小表（小表连接列无索引）-- Hash Join

```sql
EXPLAIN SELECT a.a_name, a.a_val, c.c_name, c.c_val
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
```

```
+--------------------------------+------------+-----------+---------------------+----------------------------------------------+
| id                             | estRows    | task      | access object       | operator info                                |
+--------------------------------+------------+-----------+---------------------+----------------------------------------------+
| HashJoin_11                    | 5000.00    | root      |                     | inner join, equal:[eq(test.t_join_a.a_val, test.t_join_c.c_val)] |
| ├─HashJoinBuild_13(Build)      | 500.00     | root      |                     |                                              |
| │ └─TableReader_17             | 500.00     | root      |                     | data:TableFullScan_16                        |
| │   └─TableFullScan_16         | 500.00     | cop[tikv] | table:t_join_c      | keep order:false                             |
| └─HashJoinProbe_12(Probe)      | 100000.00  | root      |                     |                                              |
|   └─TableReader_15             | 100000.00  | root      |                     | data:TableFullScan_14                        |
|     └─TableFullScan_14         | 100000.00  | cop[tikv] | table:t_join_a      | keep order:false                             |
+--------------------------------+------------+-----------+---------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `HashJoin_11` | 根算子为 Hash Join，`equal:[eq(…)]` 表示等值连接 |
| Build 子节点 | `HashJoinBuild_13 → TableFullScan_16` | Build 侧：`t_join_c`（500 行小表）全表扫描后构建哈希表 |
| Probe 子节点 | `HashJoinProbe_12 → TableFullScan_14` | Probe 侧：`t_join_a`（10 万行大表）全表扫描后逐行探测哈希表 |
| task | `root + cop[tikv]` | Build/Probe 在 TiDB(root) 协调，实际扫描在 TiKV(cop) |
| 关键问题 | `t_join_c.c_val` 无索引 | Build 侧必须全表扫描 t_join_c，无法用索引优化 |

**为什么是 Hash Join 而不是 Index Join**：`t_join_c.c_val` 没有索引，TiDB 无法用 Index Join（INLJ）。Hash Join 成为唯一选择，Build 侧对小表 t_join_c（500 行）全表扫描还算可接受，但 Probe 侧全表扫描 t_join_a（10 万行）开销很大。

---

### 场景2: 两大表等值连接（均有索引但优化器选 Hash Join）

```sql
EXPLAIN SELECT a.a_name, b.b_name, a.a_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;
```

```
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| id                             | estRows    | task      | access object            | operator info                                |
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| HashJoin_10                    | 100000.00  | root      |                          | inner join, equal:[eq(test.t_join_a.a_val, test.t_join_b.b_val)] |
| ├─HashJoinBuild_12(Build)      | 50000.00   | root      |                          |                                              |
| │ └─TableReader_16             | 50000.00   | root      |                          | data:TableFullScan_15                        |
| │   └─TableFullScan_15         | 50000.00   | cop[tikv] | table:t_join_b           | keep order:false                             |
| └─HashJoinProbe_11(Probe)      | 100000.00  | root      |                          |                                              |
|   └─TableReader_14             | 100000.00  | root      |                          | data:TableFullScan_13                        |
|     └─TableFullScan_13         | 100000.00  | cop[tikv] | table:t_join_a           | keep order:false                             |
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `HashJoin_10` | 根算子 Hash Join，两张表都有 `idx_val` 索引但未被使用 |
| Build 侧 | `TableFullScan_15(t_join_b)` | 全表扫描 5 万行，未走 `idx_val` 索引 |
| Probe 侧 | `TableFullScan_13(t_join_a)` | 全表扫描 10 万行，未走 `idx_val` 索引 |
| 关键问题 | 缺少索引提示或统计信息偏差 | 优化器认为全表扫描 + Hash Join 比 Index Join 更快 |

**为什么优化器可能不选 Index Join**：当两表都很大时，Index Join（INLJ）需要在被驱动表上做大量索引查找，每次查找都是一次随机 I/O。TiDB 优化器会权衡：如果被驱动表 estRows 很大，Hash Join（一次全扫 + 构建哈希）可能比 Index Join（大量索引随机查找）更快。当统计信息不准确时，这种选择可能出错。

---

### 场景3: 非等值连接 -- 只能走 Hash Join

```sql
EXPLAIN SELECT a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val > b.b_val;
```

```
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
| id                             | estRows    | task      | access object    | operator info                                |
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
| HashJoin_10                    | 2500000.00 | root      |                  | inner join, other cond:gt(test.t_join_a.a_val, test.t_join_b.b_val) |
| ├─HashJoinBuild_12(Build)      | 50000.00   | root      |                  |                                              |
| │ └─TableReader_16             | 50000.00   | root      |                  | data:TableFullScan_15                        |
| │   └─TableFullScan_15         | 50000.00   | cop[tikv] | table:t_join_b   | keep order:false                             |
| └─HashJoinProbe_11(Probe)      | 100000.00  | root      |                  |                                              |
|   └─TableReader_14             | 100000.00  | root      |                  | data:TableFullScan_13                        |
|     └─TableFullScan_13         | 100000.00  | cop[tikv] | table:t_join_a   | keep order:false                             |
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `HashJoin_10` | 根算子 Hash Join |
| operator info | `other cond:gt(…)` | **非等值条件**（`>`），不等 `equal:` |
| 关键限制 | 只能走 Hash Join | 非等值连接无法用 Index Join（索引只能做等值查找），Merge Join 理论上可行但需要排序 |
| estRows | `2500000.00` | 预估结果行数远超输入，非等值连接的笛卡尔积效应 |

**非等值连接的限制**：`>`, `<`, `>=`, `<=`, `BETWEEN`, `LIKE` 等非等值条件无法利用 B+Tree 索引做等值查找，因此 Index Join/INLJ 不可用。TiDB 对非等值连接只能选择 Hash Join 或 Merge Join。

---

## TiDB Join 算法 EXPLAIN 识别要点

| Join 算法 | EXPLAIN 根算子 | Build 侧特征 | Probe 侧特征 |
|-----------|---------------|-------------|-------------|
| **Hash Join** | `HashJoin_xx` | `HashJoinBuild_xx` + (TableFullScan 或 IndexReader) | `HashJoinProbe_xx` + (TableFullScan 或 IndexReader) |
| **Index Join (INLJ)** | `IndexJoin_xx` | (TableFullScan 或 IndexReader) | `IndexRangeScan_xx` 或 `IndexFullScan_xx`（**直接索引访问被驱动表**） |
| **Merge Join** | `MergeJoin_xx` | `Sort_xx` + TableReader | `Sort_xx` + TableReader（两表均需排序） |
| **Index Hash Join** | `IndexHashJoin_xx` | `HashJoinBuild_xx` + TableReader | `HashJoinProbe_xx` + **IndexReader/IndexRangeScan** |
| **Index Merge Join** | `IndexMergeJoin_xx` | `IndexLookUp_xx` 或 IndexReader | `IndexLookUp_xx` 或 IndexReader（**利用索引直接合并**） |

**核心区分方法**：
- **`equal:[eq(…)]`** -- 等值连接，多种算法可选
- **`other cond:`** -- 非等值条件，只能 Hash Join 或 Merge Join
- **Build/Probe 中是否有 `Index` 前缀的算子** -- 有则用了索引（Index Join / Index Hash Join），无则全表扫描
