# EXPLAIN 参考结果 - bad.sql（IndexLookUp 回表分析）

## TiDB v7.5.1（20 万 t_lookup + 10 万 t_cluster_lookup）

---

### 场景1: 查询列不在索引中，触发 IndexLookUp

```sql
EXPLAIN SELECT id, name, email, bio FROM t_lookup WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| id                            | estRows  | task      | access object             | operator info                      |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| IndexLookUp_7                 | 20000.00 | root      |                           |                                    |
| ├─IndexRangeScan_5(Build)     | 20000.00 | cop[tikv] | table:t_lookup, index:idx_city | range:["Beijing","Beijing"]    |
| └─TableRowIDScan_6(Probe)     | 20000.00 | cop[tikv] | table:t_lookup            | keep order:false                   |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `IndexLookUp_7` | **回表算子**：先索引扫描再聚簇索引查询 |
| task | `root` | IndexLookUp 在 TiDB 层调度，协调子节点 |
| Build 阶段 | `IndexRangeScan_5(Build)` | 扫描 `idx_city` 索引，获取匹配行对应的 `_tidb_rowid`（RowID） |
| Probe 阶段 | `TableRowIDScan_6(Probe)` | 用 Build 阶段获取的 RowID 回表读取完整行 |
| access object | `table:t_lookup, index:idx_city` | 索引扫描阶段使用 `idx_city`，回表阶段访问 `t_lookup` |
| estRows | `20000.00` | 预估 2 万行匹配 `city='Beijing'`（共 20 万行，10 个城市均匀分布） |

#### 为什么触发 IndexLookUp

查询的 `name`、`email`、`bio` 三个列都不在 `idx_city` 索引中。`idx_city` 索引的 B+Tree 叶子节点只存储 `(city, _tidb_rowid)`，无法从索引直接返回结果。

**执行流程**：
1. **Build 阶段**：通过 `IndexRangeScan` 扫描 `idx_city` 索引的 B+Tree，找到所有 `city='Beijing'` 的索引条目，获取对应的 RowID 列表
2. **Probe 阶段**：`TableRowIDScan` 根据 RowID 列表，到聚簇索引（主键 B+Tree）中逐一读取完整行，取出 `name`、`email`、`bio` 列
3. `IndexLookUp` 在 TiDB 层汇合结果返回

**核心开销**：每个匹配行都需要一次随机 I/O 回表（若数据不在 Buffer Pool 中），20000 行 = 20000 次回表。

---

### 场景2: 回表读取大量数据

```sql
EXPLAIN SELECT id, user_id, age, city, bio FROM t_lookup WHERE user_id BETWEEN 1000 AND 2000;
```

```
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object              | operator info                                |
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
| IndexLookUp_7                 | 1000.00  | root      |                            |                                              |
| ├─IndexRangeScan_5(Build)     | 1000.00  | cop[tikv] | table:t_lookup, index:idx_user | range:[1000,2000], keep order:false      |
| └─TableRowIDScan_6(Probe)     | 1000.00  | cop[tikv] | table:t_lookup             | keep order:false                             |
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `IndexLookUp_7` | 回表算子 |
| Build 阶段 | `IndexRangeScan` on `idx_user` | 扫描 `idx_user` 索引获取 RowID，范围 `[1000, 2000]` |
| Probe 阶段 | `TableRowIDScan` | 需回表读取 `age`、`city`、`bio` 列 |
| estRows | `1000.00` | user_id 分布 1~200000，范围跨度 1000 → 约 1000 行 |

#### 为什么需要回表

`idx_user` 索引只包含 `(user_id, _tidb_rowid)`，但查询需要 `age`、`city`、`bio` 三个列——这些列都不在索引中。即使 `id` 作为主键会被附加到二级索引中（TiDB 二级索引自动包含主键列），但 `age`、`city`、`bio` 仍不在索引内，必须回表。

**命中行数 vs 回表次数**：estRows=1000，意味着 1000 次 `TableRowIDScan` 回表。当范围条件覆盖的行数越多，回表开销越大。

---

### 场景3: ORDER BY + 非覆盖索引（SELECT *）

```sql
EXPLAIN SELECT * FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;
```

```
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object                 | operator info                                |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| IndexLookUp_11                | 30000.00 | root      |                               |                                              |
| ├─IndexRangeScan_8(Build)     | 30000.00 | cop[tikv] | table:t_lookup, index:idx_age_city | range:(20,30), keep order:false          |
| └─TableRowIDScan_10(Probe)    | 30000.00 | cop[tikv] | table:t_lookup                | keep order:false                             |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `IndexLookUp_11` | **仍需回表**——因为 `SELECT *` |
| Build 阶段 | `IndexRangeScan_8` on `idx_age_city` | 索引范围扫描 `age` 在 `(20, 30)` 区间 |
| 注意 | 使用了 `idx_age_city` | 索引可用于 `age` 过滤 + `city` 排序，但阻止不了回表 |
| estRows | `30000.00` | age 范围覆盖约 3 万行 |

#### 关键洞察：为何索引能排序仍需回表？

`idx_age_city(age, city)` 索引的叶子节点包含 `(age, city, _tidb_rowid)`。语句 `WHERE age > 20 AND age < 30 ORDER BY city` 中：
- **索引已经按 (age, city) 有序**，所以 Build 阶段的 IndexRangeScan 按 age 范围扫描时，天然按 city 排序，无需额外 filesort
- **但 SELECT * 需要所有列**（name, email, bio, score, created_at 等），这些列不在索引中
- 所以 TiDB 必须执行 `IndexLookUp`：Build 阶段在索引中找到满足条件的 RowID，Probe 阶段回表取完整行

如果只查索引列（`id, age, city`），则可升级为 `IndexReader` 避免回表（见 good.sql）。

---

## IndexLookUp 算子的 Build → Probe 两阶段总览

```
IndexLookUp (root task - TiDB 层调度)
├── IndexRangeScan (Build)  ← 扫描二级索引，获取 RowID 列表
│   索引 B+Tree 叶子: (index_cols, _tidb_rowid)
│   输出: RowID 列表
│
└── TableRowIDScan (Probe)  ← 根据 RowID 列表回聚簇索引读取完整行
    聚簇索引 B+Tree 叶子: (PK, all_columns)
    输出: 完整行数据
```

| 对比维度 | Build 阶段 | Probe 阶段 |
|---------|-----------|-----------|
| 访问对象 | 二级索引（如 idx_city） | 聚簇索引 / 主键 B+Tree |
| 读取内容 | 索引列 + RowID | 完整行所有列 |
| I/O 类型 | 顺序扫描索引页 | **随机 I/O** 逐行回表 |
| 行数 | 索引中匹配的行数 | 与 Build 相同（1:1 回表） |
| 性能瓶颈 | 通常不是瓶颈 | **核心瓶颈**：回表随机 I/O |
