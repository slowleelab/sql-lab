# EXPLAIN 参考结果 - good.sql（选择最优 Join 算法）

## TiDB（t_join_a 10 万行 + t_join_b 5 万行 + t_join_c 500 行）

---

### 场景1: 小表加索引后走 Index Join (INLJ)

```sql
ALTER TABLE t_join_c ADD KEY idx_val (c_val);
EXPLAIN SELECT a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
```

```
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| id                              | estRows    | task      | access object             | operator info                                |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| IndexJoin_11                    | 5000.00    | root      |                           | inner join, inner:IndexReader_10, outer key:test.t_join_a.a_val, inner key:test.t_join_c.c_val |
| ├─TableReader_14(Build)         | 100000.00  | root      |                           | data:TableFullScan_13                        |
| │ └─TableFullScan_13            | 100000.00  | cop[tikv] | table:t_join_a            | keep order:false                             |
| └─IndexReader_10(Probe)         | 10.00      | root      |                           | index:IndexRangeScan_9                       |
|   └─IndexRangeScan_9            | 10.00      | cop[tikv] | table:t_join_c, index:idx_val(c_val) | range: decided by [test.t_join_a.a_val], keep order:false |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `IndexJoin_11` | 根算子为 Index Join（INLJ），`inner:IndexReader_10` 表示内表走索引 |
| Build 侧 | `TableFullScan_13(t_join_a)` | **外表**（驱动表）：全表扫描 10 万行，逐个获取 `a_val` |
| Probe 侧 | `IndexRangeScan_9(t_join_c, idx_val)` | **内表**（被驱动表）：用外表 `a_val` 的值在 `idx_val(c_val)` 上做等值查找 |
| operator info | `outer key:…a_val, inner key:…c_val` | 明确展示外表键和内表键的对应关系 |
| estRows(Probe) | `10.00` | 内表每次索引查找预估命中 10 行（a_val 1-10000 平均每个值约 10 行，c_val 1-500 每个值 1 行，匹配约 10 行） |

**对比 bad.sql 场景1**：bad 中 `t_join_c.c_val` 无索引，只能走 Hash Join（Probe 侧全扫 10 万行）。加索引后走 Index Join（INLJ），Probe 侧每次只做索引查找，大幅减少扫描。

---

### 场景2: 等值连接 + 索引 -- 优化器自动选择

```sql
EXPLAIN SELECT a.a_name, b.b_name, a.a_val, b.b_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;
```

```
+----------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| id                               | estRows    | task      | access object            | operator info                                |
+----------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| IndexHashJoin_11                 | 100000.00  | root      |                          | inner join, inner:IndexReader_10, outer key:test.t_join_a.a_val, inner key:test.t_join_b.b_val |
| ├─TableReader_14(Build)          | 100000.00  | root      |                          | data:TableFullScan_13                        |
| │ └─TableFullScan_13             | 100000.00  | cop[tikv] | table:t_join_a           | keep order:false                             |
| └─IndexReader_10(Probe)          | 1.00       | root      |                          | index:IndexRangeScan_9                       |
|   └─IndexRangeScan_9             | 1.00       | cop[tikv] | table:t_join_b, index:idx_val(b_val) | range: decided by [test.t_join_a.a_val], keep order:false |
+----------------------------------+------------+-----------+--------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `IndexHashJoin_11` | **Index Hash Join**：外表构建哈希表 + 内表索引查找的混合算法 |
| Build 侧 | `TableFullScan_13(t_join_a)` | 外表全表扫描，构建哈希表（不同于纯 Index Join） |
| Probe 侧 | `IndexRangeScan_9(t_join_b, idx_val)` | 内表走索引范围扫描，同时用哈希表过滤 |

**Index Hash Join vs Index Join**：
- **Index Hash Join**：外表先构建哈希表，内表按索引范围扫描后用哈希表探测（适合外表较大、内表也大的场景）
- **Index Join (INLJ)**：外表每行去内表做一次索引查找（适合外表较小或内表索引选择性极高的场景）
- TiDB 优化器根据统计信息自动选择，也可通过 Hint 控制

---

### 场景3: 显式 Join Hint 控制

#### 3a. Hash Join Hint

```sql
EXPLAIN SELECT /*+ HASH_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;
```

```
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
| id                             | estRows    | task      | access object    | operator info                                |
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
| HashJoin_10                    | 100000.00  | root      |                  | inner join, equal:[eq(test.t_join_a.a_val, test.t_join_b.b_val)] |
| ├─HashJoinBuild_12(Build)      | 50000.00   | root      |                  |                                              |
| │ └─TableReader_16             | 50000.00   | root      |                  | data:TableFullScan_15                        |
| │   └─TableFullScan_15         | 50000.00   | cop[tikv] | table:t_join_b    | keep order:false                             |
| └─HashJoinProbe_11(Probe)      | 100000.00  | root      |                  |                                              |
|   └─TableReader_14             | 100000.00  | root      |                  | data:TableFullScan_13                        |
|     └─TableFullScan_13         | 100000.00  | cop[tikv] | table:t_join_a    | keep order:false                             |
+--------------------------------+------------+-----------+------------------+----------------------------------------------+
```

`/*+ HASH_JOIN(a, b) */` 强制使用 Hash Join，即使有索引也会忽略。Build 侧选较小表 `t_join_b`（5 万行）构建哈希表，Probe 侧全扫 `t_join_a`（10 万行）探测。

#### 3b. Merge Join Hint

```sql
EXPLAIN SELECT /*+ MERGE_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val WHERE a.a_val < 100;
```

```
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| id                             | estRows    | task      | access object            | operator info                                |
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
| MergeJoin_12                   | 990.00     | root      |                          | inner join, left key:test.t_join_a.a_val, right key:test.t_join_b.b_val |
| ├─IndexReader_17(Build)        | 990.00     | root      |                          | index:IndexRangeScan_16                      |
| │ └─IndexRangeScan_16          | 990.00     | cop[tikv] | table:t_join_a, index:idx_val(a_val) | range:[-inf,100), keep order:true |
| └─IndexReader_19(Probe)        | 50000.00   | root      |                          | index:IndexFullScan_18                       |
|   └─IndexFullScan_18           | 50000.00   | cop[tikv] | table:t_join_b, index:idx_val(b_val) | keep order:true                 |
+--------------------------------+------------+-----------+--------------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `MergeJoin_12` | Merge Join：两表按连接列排序后合并 |
| Build 侧 | `IndexRangeScan_16(t_join_a, idx_val)` | 利用 `idx_val` 索引有序扫描，`keep order:true` |
| Probe 侧 | `IndexFullScan_18(t_join_b, idx_val)` | 全索引扫描，`keep order:true`，按 `b_val` 有序输出 |
| operator info | `left key:…a_val, right key:…b_val` | Merge Join 的关键特征 |

**Merge Join 条件**：两表必须按连接列排序（或可利用索引自然有序）。`keep order:true` 是 Merge Join 的必要条件。

#### 3c. Index Join Hint

```sql
EXPLAIN SELECT /*+ INL_JOIN(c) */ a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
```

```
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| id                              | estRows    | task      | access object             | operator info                                |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| IndexJoin_11                    | 5000.00    | root      |                           | inner join, inner:IndexReader_10, outer key:test.t_join_a.a_val, inner key:test.t_join_c.c_val |
| ├─TableReader_14(Build)         | 100000.00  | root      |                           | data:TableFullScan_13                        |
| │ └─TableFullScan_13            | 100000.00  | cop[tikv] | table:t_join_a            | keep order:false                             |
| └─IndexReader_10(Probe)         | 10.00      | root      |                           | index:IndexRangeScan_9                       |
|   └─IndexRangeScan_9            | 10.00      | cop[tikv] | table:t_join_c, index:idx_val(c_val) | range: decided by [test.t_join_a.a_val], keep order:false |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
```

`/*+ INL_JOIN(c) */` 强制对 `t_join_c` 使用 Index Join（Index Nested Loop Join），内表（被驱动表）走索引查找。

---

### 场景4: Broadcast Join 控制

```sql
SET SESSION tidb_prefer_broadcast_join = ON;
EXPLAIN SELECT a.a_name, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
```

```
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| id                              | estRows    | task      | access object             | operator info                                |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
| HashJoin_11                     | 5000.00    | root      |                           | inner join, equal:[eq(test.t_join_a.a_val, test.t_join_c.c_val)] |
| ├─HashJoinBuild_13(Build)       | 500.00     | root      |                           |                                              |
| │ └─TableReader_17              | 500.00     | root      |                           | data:TableFullScan_16                        |
| │   └─TableFullScan_16          | 500.00     | cop[tikv] | table:t_join_c            | keep order:false                             |
| └─HashJoinProbe_12(Probe)       | 100000.00  | root      |                           |                                              |
|   └─TableReader_15              | 100000.00  | root      |                           | data:TableFullScan_14                        |
|     └─TableFullScan_14          | 100000.00  | cop[tikv] | table:t_join_a            | keep order:false                             |
+---------------------------------+------------+-----------+---------------------------+----------------------------------------------+
```

当 `tidb_prefer_broadcast_join = ON` 时，TiDB 倾向于将小表数据广播到所有 TiKV 节点，各节点在本地完成 Join 后汇总。EXPLAIN 中算子结构与普通 Hash Join 相同，区别在于执行层面的数据分布策略。

---

## TiDB Join 算法 EXPLAIN 特征速查表

| Join 算法 | 根算子 ID 前缀 | Build 侧关键算子 | Probe 侧关键算子 | operator info 特征 |
|-----------|---------------|-----------------|-----------------|-------------------|
| **Hash Join** | `HashJoin_` | `HashJoinBuild_` → (TableReader/IndexReader) | `HashJoinProbe_` → (TableReader/IndexReader) | `equal:[eq(…)]` 或 `other cond:` |
| **Index Join (INLJ)** | `IndexJoin_` | (TableReader/IndexReader) 无 Build 前缀 | `IndexReader/IndexRangeScan/IndexFullScan` | `inner:IndexReader…, outer key:…, inner key:…` |
| **Merge Join** | `MergeJoin_` | Sort + (TableReader/IndexReader) 带 `keep order:true` | Sort + (TableReader/IndexReader) 带 `keep order:true` | `left key:…, right key:…` |
| **Index Hash Join** | `IndexHashJoin_` | `HashJoinBuild_` → TableReader | `HashJoinProbe_` → **IndexReader/IndexRangeScan** | 混合 Hash + Index |
| **Index Merge Join** | `IndexMergeJoin_` | IndexReader/IndexLookUp | IndexReader/IndexLookUp | 利用索引有序合并 |

---

## Join Hint 一览

| Hint | 作用 | 适用条件 |
|------|------|---------|
| `/*+ HASH_JOIN(t1, t2) */` | 强制使用 Hash Join | 等值/非等值连接均可 |
| `/*+ MERGE_JOIN(t1, t2) */` | 强制使用 Merge Join | 需要两表按连接列排序（或有可用有序索引） |
| `/*+ INL_JOIN(t2) */` | 强制对 t2 使用 Index Join | t2 必须有可用索引 |
| `/*+ INL_HASH_JOIN(t2) */` | 强制使用 Index Hash Join | t2 必须有可用索引 |
| `/*+ INL_MERGE_JOIN(t1, t2) */` | 强制使用 Index Merge Join | 两表都有可用索引且有序 |

Hint 中 `t1, t2` 写的是查询中的表别名（alias），而非原始表名。

---

## 优化前后对比

| 对比维度 | bad.sql（非最优） | good.sql（最优） | 提升 |
|---------|------------------|-----------------|------|
| t_join_c 连接方式 | Hash Join（全表扫描 t_join_c） | Index Join（索引查找 t_join_c） | 质变 |
| t_join_c 扫描行数 | 500 行（全表） | 每次约 10 行（索引按需） | 大幅减少 |
| t_join_a 扫描行数 | 100000 行（Hash Join Probe 全扫） | 100000 行（Index Join Build 同样全扫，但 Probe 侧不同） | Build 侧不变 |
| 算法可控性 | 依赖优化器自动选择 | 通过 Hint 精确控制 | 可干预 |
| Broadcast 策略 | 默认行为 | 可通过 `tidb_prefer_broadcast_join` 控制 | 可调优 |
