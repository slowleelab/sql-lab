# EXPLAIN 参考结果 - bad.sql（TiDB 算子树解读）

## TiDB v7.5.1（10 万用户 + 30 万订单）

---

### 场景1: 全表扫描 TableFullScan

```sql
EXPLAIN SELECT * FROM t_user;
```

```
+---------------------+----------+-----------+---------------+--------------------------------+
| id                  | estRows  | task      | access object | operator info                  |
+---------------------+----------+-----------+---------------+--------------------------------+
| TableReader_5       | 100000.00| root      |               | data:TableFullScan_4           |
| └─TableFullScan_4   | 100000.00| cop[tikv] | table:t_user  | keep order:false               |
+---------------------+----------+-----------+---------------+--------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `TableReader_5 → TableFullScan_4` | 树形结构：TableReader 在 TiDB 层读取数据 |
| estRows | `100000.00` | 预估扫描 10 万行 |
| task | `root + cop[tikv]` | TableReader 在 TiDB(root)，实际扫描在 TiKV(cop) |
| access object | `table:t_user` | 访问整张 t_user 表 |
| operator info | `keep order:false` | 不保证行顺序 |

---

### 场景2: 索引范围扫描 IndexRangeScan

```sql
EXPLAIN SELECT * FROM t_user WHERE age > 18 AND age < 30;
```

```
+-------------------------------+----------+-----------+--------------------------+------------------------------------+
| id                            | estRows  | task      | access object            | operator info                      |
+-------------------------------+----------+-----------+--------------------------+------------------------------------+
| IndexLookUp_7                 | 18332.00 | root      |                          |                                    |
| ├─IndexRangeScan_5(Build)     | 18332.00 | cop[tikv] | table:t_user, index:idx_age | range:(18,30), keep order:false|
| └─TableRowIDScan_6(Probe)     | 18332.00 | cop[tikv] | table:t_user             | keep order:false                   |
+-------------------------------+----------+-----------+--------------------------+------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `IndexLookUp_7` | 回表算子：先索引再聚簇 |
| 子节点 | `IndexRangeScan_5 (Build)` + `TableRowIDScan_6 (Probe)` | Build 扫描索引获取 RowID，Probe 用 RowID 回表 |
| access object | `table:t_user, index:idx_age` | 索引扫描阶段使用 idx_age |
| task | `cop[tikv]` | 全部在 TiKV 完成 |

---

### 场景3: IndexLookUp 回表（非覆盖索引）

```sql
EXPLAIN SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| id                            | estRows  | task      | access object             | operator info                      |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| IndexLookUp_7                 | 10000.00 | root      |                           |                                    |
| ├─IndexRangeScan_5(Build)     | 10000.00 | cop[tikv] | table:t_user, index:idx_city | range:["Beijing","Beijing"]    |
| └─TableRowIDScan_6(Probe)     | 10000.00 | cop[tikv] | table:t_user              | keep order:false                   |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
```

#### 为什么需要 IndexLookUp

查询的 name/city/salary 三列不在 idx_city 索引中。TiDB 无法用覆盖索引直接返回，必须：
1. **Build 阶段**：通过 `IndexRangeScan_5` 扫描 idx_city 索引，获取匹配行对应的 RowID
2. **Probe 阶段**：通过 `TableRowIDScan_6` 用 RowID 回聚簇索引读取完整行

---

### 场景4: Group By 聚合（HashAgg + cop task）

```sql
EXPLAIN SELECT city, COUNT(*) AS cnt, AVG(salary) AS avg_salary FROM t_user GROUP BY city ORDER BY cnt DESC;
```

```
+------------------------------+----------+-----------+---------------+----------------------------------+
| id                           | estRows  | task      | access object | operator info                     |
+------------------------------+----------+-----------+---------------+----------------------------------+
| Projection_7                 | 10.00    | root      |               | ...                               |
| └─Sort_8                     | 10.00    | root      |               | ...                               |
|   └─HashAgg_11               | 10.00    | root      |               | group by:t_user.city, funcs:...   |
|     └─TableReader_12         | 100000.00| root      |               | data:TableFullScan_10             |
|       └─TableFullScan_10     | 100000.00| cop[tikv] | table:t_user  | keep order:false                  |
+------------------------------+----------+-----------+---------------+----------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| HashAgg_11 | `root task` | 聚合在 TiDB 层进行，无法下推到 TiKV |
| TableFullScan_10 | `cop[tikv]` | 全表扫描在 TiKV 完成 |
| 瓶颈 | 全表扫描 | 10 万行拉取到 TiDB 后聚合 |

---

### MySQL EXPLAIN vs TiDB EXPLAIN 对照

| 概念 | MySQL EXPLAIN | TiDB EXPLAIN |
|------|---------------|--------------|
| 格式 | 扁平表（每行一个表） | 树形结构（每行一个算子） |
| 扫描行数 | `rows` 列 | `estRows` 列 |
| 索引使用 | `key` + `key_len` + `ref` | `access object` 列 |
| 执行位置 | `Extra` 列（如 Using index） | `task` 列（root/cop[tikv]/cop[tiflash]/MPP） |
| 全表扫描 | `type: ALL` | `TableFullScan` 算子 |
| 索引扫描 | `type: range/ref` | `IndexRangeScan` / `IndexFullScan` 算子 |
| 回表 | `Extra: Using index condition` 暗示 | `IndexLookUp` 算子显式展示 |
| 覆盖索引 | `Extra: Using index` | `IndexReader` 算子（无 IndexLookUp） |
