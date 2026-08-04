# TiDB EXPLAIN 算子树解读

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['EXPLAIN', '算子树', 'operator', '执行计划', 'TiDB']" />

## MySQL DBA 接手 TiDB：EXPLAIN 树怎么读
你是一名有多年 MySQL 经验的 DBA，刚接手公司的 TiDB 集群。某天你习惯性地敲下：

```sql
EXPLAIN SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';
```

然后你愣住了——出来的不是熟悉的 12 列扁平输出（`id | select_type | table | type | key | rows | Extra`），而是一个**树形结构**，每行一个“算子”，列名变成了 `id | estRows | task | access object | operator info`：

```
+-------------------------------+----------+-----------+---------------------------+---------------------------------+
| id                            | estRows  | task      | access object             | operator info                   |
+-------------------------------+----------+-----------+---------------------------+---------------------------------+
| IndexLookUp_7                 | 10000.00 | root      |                           |                                 |
| ├─IndexRangeScan_5(Build)     | 10000.00 | cop[tikv] | table:t_user, index:idx_city | range:["Beijing","Beijing"] |
| └─TableRowIDScan_6(Probe)     | 10000.00 | cop[tikv] | table:t_user              | keep order:false                |
+-------------------------------+----------+-----------+---------------------------+---------------------------------+
```

::: warning 真实场景
几乎所有从 MySQL 迁移到 TiDB 的 DBA 都会经历这个"文化冲击"：MySQL 的 `type: ALL` 变成了 `TableFullScan`，`Extra: Using index` 变成了 `IndexReader`，`Using temporary` 变成了 `HashAgg`。更关键的是，TiDB 的 EXPLAIN 是**树形结构**，读执行计划需要从上往下、从外往里理解算子嵌套关系。
:::

## 问题分析

### bad.sql：四种常见执行计划场景

本案例通过四个场景帮助理解 TiDB EXPLAIN 的算子树：

```sql
-- 场景1: 全表扫描 TableFullScan
EXPLAIN SELECT * FROM t_user;

-- 场景2: 索引范围扫描 IndexRangeScan（带 IndexLookUp 回表）
EXPLAIN SELECT * FROM t_user WHERE age > 18 AND age < 30;

-- 场景3: IndexLookUp 回表（非覆盖索引）
EXPLAIN SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';

-- 场景4: Group By 聚合（HashAgg 在 root task 执行）
EXPLAIN SELECT city, COUNT(*) AS cnt, AVG(salary) AS avg_salary
FROM t_user
GROUP BY city
ORDER BY cnt DESC;
```

### TiDB EXPLAIN 的 5 列含义

与 MySQL 的 12 列不同，TiDB EXPLAIN 只有 **5 列**，但信息密度很高：

| TiDB 列 | 含义 | MySQL 近似对应 |
|---------|------|---------------|
| `id` | 算子名称和树形层级 | `id` + `select_type` |
| `estRows` | 预估行数 | `rows` |
| `task` | 执行位置：`root`（TiDB层）/ `cop[tikv]`（TiKV层）/ `cop[tiflash]` / `MPP` | 无（MySQL 单机无此概念） |
| `access object` | 访问的数据对象（表名、索引名、分区名） | `table` + `key` + `ref` |
| `operator info` | 算子细节（过滤条件、聚合函数、排序等） | `Extra` + `filtered` |

### 场景1 解读：TableFullScan

```
TableReader_5       | root      |               | data:TableFullScan_4
└─TableFullScan_4   | cop[tikv] | table:t_user  | keep order:false
```

- `TableFullScan_4` 算子：对应 MySQL 的 `type: ALL`，全表扫描
- `task: cop[tikv]`：实际扫描在 TiKV 节点完成（**计算下推**）
- `TableReader_5`：TiDB server 层的读取算子，从 TiKV 获取扫描结果
- 这个两层结构展示了 TiDB 的经典模式：**计算在 TiKV 执行，结果在 TiDB 层汇总**

### 场景2 解读：IndexRangeScan + IndexLookUp

```
IndexLookUp_7                 | root      |
├─IndexRangeScan_5(Build)     | cop[tikv] | table:t_user, index:idx_age | range:(18,30)
└─TableRowIDScan_6(Probe)     | cop[tikv] | table:t_user                | keep order:false
```

- `IndexLookUp_7`：回表算子，TiDB 特有的显式回表语义
- **(Build)** 阶段：`IndexRangeScan_5` 扫描 `idx_age` 索引，获取符合条件的 RowID
- **(Probe)** 阶段：`TableRowIDScan_6` 用 RowID 回聚簇索引读取完整行
- 与 MySQL 的隐式回表不同，TiDB **显式展示回表的两阶段**：Build 和 Probe

### 场景3 解读：为什么需要 IndexLookUp

查询 `SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing'` 中，`idx_city(city)` 索引只有 `city` + 主键 `id`，而 `name`、`salary` 不在索引中。

TiDB 无法用覆盖索引直接返回，必须：
1. **Build 阶段**：扫描 `idx_city` 找到所有 `city='Beijing'` 的 RowID
2. **Probe 阶段**：用 RowID 回表读取 `name`、`salary` 字段

::: info IndexLookUp 不等于慢
IndexLookUp 是 TiDB 的正常查询路径，只有当 Build 阶段返回大量 RowID 时才会成为瓶颈。可以通过 EXPLAIN ANALYZE 查看 `actRows` 和 `exec info` 来评估实际影响。
:::

### 场景4 解读：root task 聚合

```
Projection_7       | root      |
└─Sort_8           | root      |
  └─HashAgg_11     | root      | group by:t_user.city, funcs:...
    └─TableReader_12| root      | data:TableFullScan_10
      └─TableFullScan_10 | cop[tikv] | table:t_user | keep order:false
```

- `HashAgg_11` 的 `task: root` 表示聚合在 TiDB server 层完成
- 全表扫描 `TableFullScan_10` 在 TiKV 执行（`cop[tikv]`），10 万行被拉取到 TiDB 层做聚合
- 如果聚合函数支持，TiDB 可以将其下推到 TiKV（`task: cop[tikv]`），大幅减少网络传输

## 优化方案

### good.sql：TiDB EXPLAIN 高级用法

```sql
-- 1. EXPLAIN ANALYZE: 实际执行并显示真实耗时
EXPLAIN ANALYZE SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';

-- 2. FORMAT=verbose: 更详细的算子信息
EXPLAIN FORMAT=verbose SELECT city, COUNT(*) AS cnt FROM t_user GROUP BY city;

-- 3. 覆盖索引避免回表（IndexReader 替代 IndexLookUp）
EXPLAIN SELECT city FROM t_user WHERE city = 'Beijing';
```

### EXPLAIN ANALYZE 深度解读

```
IndexLookUp_7                 | estRows:10000 | actRows:9800 | root      | time:8.2ms, memory:1.2 MB
├─IndexRangeScan_5(Build)     | estRows:10000 | actRows:9800 | cop[tikv] | time:2.1ms
└─TableRowIDScan_6(Probe)     | estRows:10000 | actRows:9800 | cop[tikv] | time:4.8ms
```

`EXPLAIN ANALYZE` 新增 4 列：

| 新增列 | 说明 | 用途 |
|--------|------|------|
| `actRows` | 算子实际返回行数 | 对比 `estRows` 发现统计信息偏差 |
| `exec info` | 算子耗时（time）、内存（memory）、磁盘（disk） | 定位真正的性能瓶颈 |
| `memory` | 算子内存占用 | 发现内存热点算子 |
| `disk` | 算子溢出到磁盘的数据量 | 发现内存不足导致的磁盘 I/O |

#### 关键发现

- `estRows=10000` vs `actRows=9800`：统计信息准确，预估值接近实际值
- Build 耗时 2.1ms，Probe 耗时 4.8ms：**回表耗时是索引扫描的 2 倍**
- 总耗时 8.2ms，无磁盘溢出

### 覆盖索引优化（核心技巧）

将查询改为 `SELECT city FROM t_user WHERE city = 'Beijing'`，只查索引中已有的列：

```
IndexReader_6                 | 10000.00 | root      |               | index:IndexRangeScan_5
└─IndexRangeScan_5            | 10000.00 | cop[tikv] | table:t_user, index:idx_city | range:["Beijing","Beijing"]
```

`IndexReader_6` 替代了 `IndexLookUp_7`，直接读索引，**完全消除回表**。

### bad vs good 量化对比

| 指标 | bad.sql（非覆盖索引）| good.sql（覆盖索引）| 提升 |
|------|--------------------|--------------------|------|
| 最外层算子 | `IndexLookUp_7` | `IndexReader_6` | 少一层回表 |
| 回表 | 需要 TableRowIDScan | **不需要** | 0 次回表 |
| 阶段数 | 两阶段（Build+Probe）| 单阶段 | 减少 50% |
| 预估耗时 | ~8ms | ~3ms | **约 2.6x** |
| 网络传输 | RowID 回表需要额外 I/O | 索引直接返回 | I/O 降为 O(1) |

## 避坑指南

::: warning TiDB EXPLAIN 常见误区

1. **EXPLAIN 不执行实际查询**。与 MySQL 一样，`EXPLAIN` 只生成执行计划，不真正执行。需要 `EXPLAIN ANALYZE` 才能看到实际行数和耗时。

2. **`stats:pseudo` 是个危险信号**。如果 EXPLAIN 输出包含 `stats:pseudo`，说明该表没有统计信息或统计信息已过期。这会导致 `estRows` 严重失准，进而导致优化器选错执行计划。应及时执行 `ANALYZE TABLE`。

3. **IndexLookUp 不等于慢查询**。IndexLookUp 是正常的查询路径，只有当返回行数很大时才会成为瓶颈。关注 `estRows` 和 `actRows` 的实际值，而不是 IndexLookUp 本身。

4. **task 列至关重要**。`cop[tikv]` 表示下推到 TiKV 执行（好），`root` 表示在 TiDB server 执行。大量 `root` 任务意味着很多数据被拉到 TiDB 层处理，可能是性能瓶颈。

5. **EXPLAIN FORMAT 多样选择**。TiDB 支持 `FORMAT=row`（默认树形）、`FORMAT=verbose`（详细）、`FORMAT=dot`（Graphviz 图形）、`EXPLAIN ANALYZE`（实际执行），不同场景用不同格式。

6. **TiFlash 的 MPP 模式**。如果集群有 TiFlash 副本，可能看到 `task: cop[tiflash]` 和 `MPP` 任务。这是 TiDB 的列存引擎和并行计算模式，与 TiKV 的执行路径完全不同。

7. **不要用 MySQL 思维读 TiDB EXPLAIN**。MySQL 的 `type` 列告诉你"怎么访问表"，TiDB 的 `id` 列告诉你"整个查询的执行树"。先从最内层算子读起，自底向上理解数据流。
:::

### TiDB vs MySQL EXPLAIN 速查表

对于从 MySQL 转过来的 DBA，这个对照表可以快速完成概念映射：

| 你想知道的 | MySQL EXPLAIN 怎么看 | TiDB EXPLAIN 怎么看 |
|-----------|---------------------|---------------------|
| 全表扫描 | `type: ALL` | 找 `TableFullScan` 算子 |
| 索引扫描 | `type: range / ref` | 找 `IndexRangeScan` / `IndexFullScan` 算子 |
| 用了哪个索引 | `key` 列 | `access object` 列（如 `index:idx_city`）|
| 覆盖索引 | `Extra: Using index` | 最外层是 `IndexReader`（非 `IndexLookUp`）|
| 需要回表 | `Extra: Using index condition` / Extra 为 NULL | 出现 `IndexLookUp` + `TableRowIDScan` |
| 扫描行数 | `rows` 列 | `estRows` 列 |
| 实际行数 | EXPLAIN ANALYZE（MySQL 8.0.18+）| `EXPLAIN ANALYZE` 的 `actRows` |
| 文件排序 | `Extra: Using filesort` | 找 `Sort` 算子 |
| 临时表 | `Extra: Using temporary` | 找 `HashAgg` 算子 |
| 是否下推到存储引擎 | `Extra: Using index condition`（部分）| `task: cop[tikv]` vs `task: root` |

## 本地复现

```bash
./scripts/run-case.sh 81-tidb-explain-tree --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```
:::
