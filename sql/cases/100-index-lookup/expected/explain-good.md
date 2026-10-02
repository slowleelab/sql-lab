# EXPLAIN 参考结果 - good.sql（覆盖索引消除 IndexLookUp）

## TiDB v7.5.1（20 万 t_lookup + 10 万 t_cluster_lookup）

---

### 正解1: 覆盖索引 —— IndexReader 替代 IndexLookUp

```sql
EXPLAIN SELECT id, city FROM t_lookup WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexReader_6                 | 20000.00 | root      |                           | index:IndexRangeScan_5           |
| └─IndexRangeScan_5            | 20000.00 | cop[tikv] | table:t_lookup, index:idx_city | range:["Beijing","Beijing"]  |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `IndexReader_6` | **覆盖索引算子**，直接从索引返回结果 |
| 子节点 | `IndexRangeScan_5` | 扫描 `idx_city` 索引 |
| 关键差异 | **无 IndexLookUp，无 TableRowIDScan** | 没有 Build/Probe 两阶段 |

#### 为什么不需要回表？

`idx_city` 是二级索引，TiDB 中每个二级索引的叶子节点自动包含主键列 `id`。索引存储为：

```
idx_city B+Tree 叶子: (city, _tidb_rowid) → 其中 _tidb_rowid 即 id
```

查询 `SELECT id, city` 的两个列（`city` + `id`）都在索引中，TiDB 优化器判定为"覆盖索引"，直接用 `IndexReader` 扫描索引返回结果——**零回表**。

---

### 正解2: 联合索引覆盖多列查询

```sql
EXPLAIN SELECT id, age, city FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;
```

```
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object                 | operator info                                |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| IndexReader_6                 | 30000.00 | root      |                               | index:IndexRangeScan_5                       |
| └─IndexRangeScan_5            | 30000.00 | cop[tikv] | table:t_lookup, index:idx_age_city | range:(20,30), keep order:false          |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `IndexReader_6` | 覆盖索引，无需回表 |
| 索引 | `idx_age_city(age, city)` | 联合索引覆盖了 WHERE + SELECT + ORDER BY 全部需求 |

#### 关键洞察

`idx_age_city(age, city)` 的索引叶子节点存储 `(age, city, _tidb_rowid)`，即 `(age, city, id)`。查询的 `id, age, city` 三个列全部在索引中：

- `age`：索引前缀列，用于 WHERE 范围过滤
- `city`：索引第二列，用于 ORDER BY 排序（索引已按 (age, city) 有序）
- `id`：主键列，自动附加在二级索引中

**对比 bad.sql 场景3**：同样的 WHERE 条件，但 bad.sql 用了 `SELECT *`，触发 IndexLookUp；这里只查索引列，升级为 IndexReader。**3 万行 × 消除回表 = 巨大的性能提升**。

---

### 正解3: Cluster Index 主键查询

```sql
EXPLAIN SELECT * FROM t_cluster_lookup WHERE id = 50000;
```

```
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
| id                    | estRows  | task      | access object                 | operator info                    |
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
| Point_Get_1           | 1.00     | root      | table:t_cluster_lookup        | handle:50000                     |
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `Point_Get_1` | **点查算子**——最优的主键查询路径 |
| operator info | `handle:50000` | 直接通过主键值定位行 |
| 关键特征 | 无 IndexLookUp、无 IndexReader | 单算子完成，无子节点依赖 |

#### Cluster Index 的特性

TiDB 中 `PRIMARY KEY (id) /* CLUSTERED */` 将主键作为聚簇索引，表数据按主键排序存储。`WHERE id = 50000` 等价于在聚簇索引 B+Tree 中做一次精确查找，一次定位到目标行，读取所有列。

**不需要回表**，因为主键 B+Tree 的叶子节点就是完整的行数据。

---

### 对比：普通表主键查询同样高效

```sql
EXPLAIN SELECT * FROM t_lookup WHERE id = 50000;
```

```
+-----------------------+----------+-----------+-------------------+----------------------------------+
| id                    | estRows  | task      | access object     | operator info                    |
+-----------------------+----------+-----------+-------------------+----------------------------------+
| Point_Get_1           | 1.00     | root      | table:t_lookup    | handle:50000                     |
+-----------------------+----------+-----------+-------------------+----------------------------------+
```

同样走 `Point_Get` 算子。TiDB 中无论是否显式声明 CLUSTERED，主键都是聚簇索引，主键点查不需要回表。

---

### 正解4: 建立专用覆盖索引

```sql
ALTER TABLE t_lookup ADD KEY idx_city_name (city, name);
EXPLAIN SELECT id, city, name FROM t_lookup WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+--------------------------------+----------------------------------+
| id                            | estRows  | task      | access object                  | operator info                    |
+-------------------------------+----------+-----------+--------------------------------+----------------------------------+
| IndexReader_6                 | 20000.00 | root      |                                | index:IndexRangeScan_5           |
| └─IndexRangeScan_5            | 20000.00 | cop[tikv] | table:t_lookup, index:idx_city_name | range:["Beijing","Beijing"] |
+-------------------------------+----------+-----------+--------------------------------+----------------------------------+
```

#### 分析

新增 `idx_city_name(city, name)` 后，索引叶子节点为 `(city, name, id)`。查询 `SELECT id, city, name` 的三列完全被索引覆盖，优化器自动选择 `IndexReader`。

**这是实际工作中最常用的优化手段**：分析高频查询的列组合，针对性建立覆盖索引。

---

## IndexLookUp vs IndexReader 核心对比

| 对比维度 | IndexLookUp（bad.sql） | IndexReader（good.sql） |
|---------|----------------------|------------------------|
| 执行阶段 | **两阶段**：Build → Probe | **单阶段**：直接扫描索引 |
| 回表 | 需要 `TableRowIDScan` | **不需要**回表 |
| 访问对象 | 二级索引 + 聚簇索引 | 仅二级索引 |
| I/O 次数 | 索引页 + 逐行随机回表 | 仅顺序扫描索引页 |
| EXPLAIN 标志 | 出现 `IndexLookUp` | 出现 `IndexReader` |
| MySQL 对应 | `Extra: Using index condition` | `Extra: Using index` |
| 性能特征 | 行数越多越慢（回表 O(n)） | 行数线性增长但无随机 I/O |
| 适用场景 | 需要索引外的列 | 查询列都在索引中 |

### 性能差异量化（20 万行表，2 万行匹配 city='Beijing'）

| 场景 | 算子 | 索引扫描 | 回表次数 | 典型耗时 |
|------|------|---------|---------|---------|
| `SELECT id, name, email, bio` | IndexLookUp | 2 万行 | 2 万次 | ~15-30ms |
| `SELECT id, city` | IndexReader | 2 万行 | **0** | ~3-5ms |

### 选型指南

```
需要查询的列是否全部在某个索引中？
├── 是 → IndexReader（覆盖索引，零回表，最优）
│   策略: 建立包含所需列的联合索引
│
└── 否 → IndexLookUp（需要回表）
    ├── 回表行数少（< 几百行）→ 可接受，IndexLookUp 开销可控
    ├── 回表行数多（> 数千行）→ 考虑建覆盖索引，或用 LIMIT 限制回表量
    └── 主键查询 → Point_Get（聚簇索引直接定位），与 IndexLookUp 无关
```
