# IndexLookUp 回表与覆盖索引

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['IndexLookUp', '回表', '覆盖索引', 'IndexReader', 'Cluster Index', 'Build/Probe']" />

## 场景痛点

TiDB 管理后台的列表页突然变慢了。EXPLAIN 一看，执行计划里出现了 `IndexLookUp` 算子，`estRows` 显示扫描了 2 万行。运维凭 MySQL 经验判断"走了索引应该不慢"，但实际响应时间从 5ms 飙升到 30ms。

```sql
-- 管理后台列表页：按城市查用户，显示姓名、邮箱、简介
SELECT id, name, email, bio FROM t_lookup WHERE city = 'Beijing';
-- EXPLAIN 显示 IndexLookUp，回表 2 万次
```

问题是：`idx_city` 索引确实被用上了，但**索引里只有 city 和 rowid，name/email/bio 都不在索引中**——每次匹配都要回表读完整行。2 万行匹配 = 2 万次随机 I/O 回表。

::: warning 真实场景

TiDB 的 EXPLAIN 与 MySQL 不同：MySQL 用 `Extra: Using index condition` 这种隐含方式表示回表，而 TiDB **显式展示 `IndexLookUp` 算子及其 Build/Probe 两阶段结构**。理解 IndexLookUp 是 TiDB 性能优化的核心基础——从"咦，走了索引怎么还慢"到"原来是回表导致的"只需要看懂 IndexLookUp 算子。

:::

## 问题分析

本案例创建两张表对比：

- `t_lookup`：普通表（20 万行），有 `idx_city`、`idx_user`、`idx_age_city` 三个二级索引
- `t_cluster_lookup`：Cluster Index 表（10 万行），主键即聚簇索引，验证主键查询无回表

### TiDB 二级索引的存储结构

理解 IndexLookUp 之前，必须先理解 TiDB 二级索引的存储结构：

```
聚簇索引 (PRIMARY KEY B+Tree):
  叶子节点: (id, user_id, name, email, age, city, bio, score, created_at)
  
二级索引 idx_city B+Tree:
  叶子节点: (city, _tidb_rowid)  ← _tidb_rowid 即主键 id
```

TiDB 的二级索引与 MySQL InnoDB 一样，叶子节点只存索引列 + 主键值（RowID）。当查询需要索引外的列时，必须用 RowID 去聚簇索引中回表读取完整行。

### bad.sql（3 个触发 IndexLookUp 的场景）

```sql
-- 场景1: 查询列不在索引中，触发 IndexLookUp
EXPLAIN SELECT id, name, email, bio FROM t_lookup WHERE city = 'Beijing';

-- 场景2: 回表读取大量数据
EXPLAIN SELECT id, user_id, age, city, bio FROM t_lookup WHERE user_id BETWEEN 1000 AND 2000;

-- 场景3: ORDER BY + 非覆盖索引
EXPLAIN SELECT * FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;
```

### EXPLAIN 结果

**场景1**：`IndexLookUp` 回表算子

```
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| id                            | estRows  | task      | access object             | operator info                      |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
| IndexLookUp_7                 | 20000.00 | root      |                           |                                    |
| ├─IndexRangeScan_5(Build)     | 20000.00 | cop[tikv] | table:t_lookup, index:idx_city | range:["Beijing","Beijing"]    |
| └─TableRowIDScan_6(Probe)     | 20000.00 | cop[tikv] | table:t_lookup            | keep order:false                   |
+-------------------------------+----------+-----------+---------------------------+------------------------------------+
```

**场景2**：即使走索引也需要回表

```
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object              | operator info                                |
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
| IndexLookUp_7                 | 1000.00  | root      |                            |                                              |
| ├─IndexRangeScan_5(Build)     | 1000.00  | cop[tikv] | table:t_lookup, index:idx_user | range:[1000,2000], keep order:false      |
| └─TableRowIDScan_6(Probe)     | 1000.00  | cop[tikv] | table:t_lookup             | keep order:false                             |
+-------------------------------+----------+-----------+----------------------------+----------------------------------------------+
```

**场景3**：索引可用于排序，SELECT * 强制回表

```
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object                 | operator info                                |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| IndexLookUp_11                | 30000.00 | root      |                               |                                              |
| ├─IndexRangeScan_8(Build)     | 30000.00 | cop[tikv] | table:t_lookup, index:idx_age_city | range:(20,30), keep order:false          |
| └─TableRowIDScan_10(Probe)    | 30000.00 | cop[tikv] | table:t_lookup                | keep order:false                             |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
```

### 为什么 IndexLookUp 慢

IndexLookUp 的两阶段执行模型：

```
Build 阶段:
  IndexRangeScan → 扫描二级索引 idx_city
  输出: [(city='Beijing', rowid=100), (city='Beijing', rowid=52341), ...]  ← 2 万行

Probe 阶段:
  TableRowIDScan → 根据 rowid 去聚簇索引逐行读取完整行
  I/O 模式: 随机 I/O（每行一次回表，2 万行 = 2 万次随机读取）
```

| 对比维度 | Build 阶段 | Probe 阶段 |
|---------|-----------|-----------|
| 访问对象 | 二级索引 | 聚簇索引 |
| I/O 类型 | 顺序扫描索引页 | **随机 I/O** 逐行回表 |
| 性能瓶颈 | 通常不是瓶颈 | **核心瓶颈** |

::: tip 核心认知

TiDB 的 `IndexLookUp` 算子等价于 MySQL 的回表操作，但 TiDB 将其显式展示为 Build（索引扫描获取 RowID）和 Probe（RowID 回表读取完整行）两个阶段。**看到 IndexLookUp 就知道有回表，看到 IndexReader 就知道是覆盖索引（零回表）**。这与 MySQL `Extra: Using index` vs `Extra: Using index condition` 表达的是同一层含义，但 TiDB 的结构化展示更清晰。

:::

## 优化方案

### good.sql

```sql
-- 正解1: 只查索引中的列（覆盖索引）
EXPLAIN SELECT id, city FROM t_lookup WHERE city = 'Beijing';

-- 正解2: 利用 idx_age_city 覆盖索引（age + city + id）
EXPLAIN SELECT id, age, city FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;

-- 正解3: Cluster Index 表的主键查询
EXPLAIN SELECT * FROM t_cluster_lookup WHERE id = 50000;

-- 对比：普通表主键查询同样高效
EXPLAIN SELECT * FROM t_lookup WHERE id = 50000;

-- 正解4: 建立专用覆盖索引
ALTER TABLE t_lookup ADD KEY idx_city_name (city, name);
EXPLAIN SELECT id, city, name FROM t_lookup WHERE city = 'Beijing';
```

### EXPLAIN 优化后结果

**正解1**：`IndexReader` 替代 `IndexLookUp`

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexReader_6                 | 20000.00 | root      |                           | index:IndexRangeScan_5           |
| └─IndexRangeScan_5            | 20000.00 | cop[tikv] | table:t_lookup, index:idx_city | range:["Beijing","Beijing"]  |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

对比 bad.sql 场景1：`IndexLookUp → IndexReader`，`TableRowIDScan` 消失——零回表。

**正解2**：联合索引覆盖多列

```
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| id                            | estRows  | task      | access object                 | operator info                                |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
| IndexReader_6                 | 30000.00 | root      |                               | index:IndexRangeScan_5                       |
| └─IndexRangeScan_5            | 30000.00 | cop[tikv] | table:t_lookup, index:idx_age_city | range:(20,30), keep order:false          |
+-------------------------------+----------+-----------+-------------------------------+----------------------------------------------+
```

**正解3**：Cluster Index 的 Point_Get

```
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
| id                    | estRows  | task      | access object                 | operator info                    |
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
| Point_Get_1           | 1.00     | root      | table:t_cluster_lookup        | handle:50000                     |
+-----------------------+----------+-----------+-------------------------------+----------------------------------+
```

主键点查直接走 `Point_Get` 算子——TiDB 最优的查询路径，与 IndexLookUp 无关。

### 原理

**覆盖索引消除回表**的核心在于 TiDB 二级索引的存储结构：

```
idx_city B+Tree 叶子: (city, _tidb_rowid)
  其中 _tidb_rowid = 主键 id

查询 SELECT id, city → city 和 id 都在索引叶子节点中
→ TiDB 优化器判定为"覆盖索引"
→ 使用 IndexReader 直接从索引返回结果
→ 不需要 TableRowIDScan 回表
```

**Cluster Index** 的机制：

TiDB 中 `PRIMARY KEY` 默认就是聚簇索引（等同于 MySQL InnoDB 的主键即聚簇）。表数据按主键排序存储在主键 B+Tree 中，叶子节点是完整的行数据。主键点查一次定位到目标行，无需回表。

### 三种优化手段对照

| 优化手段 | EXPLAIN 算子 | 回表 | 适用场景 |
|---------|-------------|------|---------|
| 覆盖索引 | `IndexReader` | 无 | 查询列都在索引中 |
| Cluster Index 点查 | `Point_Get` | 无 | 主键精确查询 |
| 建立联合索引 | `IndexReader` | 无 | 高频多列查询需覆盖 |

## 深入原理

### TiDB IndexLookUp 的执行流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IndexLookUp (TiDB root task)                  │
│                                                                     │
│  ┌─────────────────────────┐       ┌─────────────────────────────┐  │
│  │  Build 阶段              │       │  Probe 阶段                  │  │
│  │                         │       │                             │  │
│  │  IndexRangeScan         │  ───► │  TableRowIDScan             │  │
│  │  (扫描二级索引)          │ RowID │  (回表读聚簇索引)            │  │
│  │                         │       │                             │  │
│  │  cop[tikv]              │       │  cop[tikv]                  │  │
│  │  顺序扫描 B+Tree 索引页  │       │  随机 I/O 逐行回表           │  │
│  └─────────────────────────┘       └─────────────────────────────┘  │
│                                                                     │
│  输出: RowID 列表                    输出: 完整行数据                  │
└─────────────────────────────────────────────────────────────────────┘
```

1. **Build 阶段**（`IndexRangeScan`）：在 TiKV 上扫描二级索引的 B+Tree，根据 WHERE 条件过滤，获取匹配行对应的 `_tidb_rowid`（主键值）。这一步是顺序扫描索引页，效率较高。

2. **Probe 阶段**（`TableRowIDScan`）：将 Build 阶段收集的 RowID 列表交给 TiKV，逐一去聚簇索引 B+Tree 中查找完整行。**每次查找都是随机 I/O**（除非数据页已在 Buffer Pool 中缓存），这是 IndexLookUp 的性能瓶颈。

3. **任务调度**：`IndexLookUp` 的 task 类型是 `root`，表示在 TiDB SQL 层协调调度，而子节点的 task 是 `cop[tikv]`，表示实际扫描在 TiKV 上执行。

### IndexLookUp vs IndexReader 选型指南

```
查询列 全部 ∈ 某个索引的列？
│
├── 是 → IndexReader
│   └── 覆盖索引，零回表，最优路径
│       策略: 建联合索引覆盖查询列
│       示例: SELECT id, city FROM t WHERE city='X'  -- idx_city(city) 覆盖
│
└── 否 → IndexLookUp
    ├── 回表行数 < 几百行 → 可接受，IndexLookUp 开销可控
    │   示例: SELECT * FROM t WHERE user_id=123  -- 1-2 行回表可忽略
    │
    ├── 回表行数 > 数千行 → 考虑优化
    │   策略 A: 建覆盖索引（如果查询列固定）
    │   策略 B: 用 LIMIT 限制回表量
    │   策略 C: 拆分查询，先 SELECT id（覆盖索引）再 INNER JOIN 补充列
    │
    └── 主键查询 → Point_Get（聚簇索引直接定位，无回表概念）
```

### MySQL 回表 vs TiDB IndexLookUp 对比

| 概念 | MySQL InnoDB | TiDB |
|------|-------------|------|
| 回表机制 | 二级索引 → 聚簇索引（同节点内） | 二级索引 → 聚簇索引（可能跨 TiKV 节点） |
| EXPLAIN 表示 | `Extra: Using index condition` | `IndexLookUp` 算子（显式 Build/Probe） |
| 覆盖索引表示 | `Extra: Using index` | `IndexReader` 算子 |
| 主键查询 | type: const | `Point_Get` 算子 |
| 执行位置 | 单机（同一 MySQL 实例） | 分布式（TiKV 节点间可能跨网络） |
| 回表成本 | 随机 I/O（磁盘/内存） | 随机 I/O + 可能的跨节点网络延迟 |

### TiDB 额外的分布式考量

在 TiDB 架构中，回表除了随机 I/O 开销外，还需要考虑：

- **跨 Region 回表**：RowID 对应的行可能分布在不同的 TiKV Region（甚至不同 TiKV 节点），每次回表可能涉及跨节点 RPC 调用
- **Batch 优化**：TiDB 会对 RowID 列表做批量回表（而非逐行），减少 RPC 次数，但本质仍是随机读取
- **Coprocessor 下推**：Build 和 Probe 的 cop[tikv] 任务都在 TiKV 节点的 Coprocessor 中执行，减少数据传输

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 86-index-lookup --ver tidb
```

执行后观察：
- `EXPLAIN SELECT ...` 输出的算子树结构
- bad.sql 中出现 `IndexLookUp`（Build + Probe 两阶段）
- good.sql 中出现 `IndexReader`（覆盖索引，单阶段）
- `t_cluster_lookup` 的主键查询走 `Point_Get`

::: tip 如何判断是否需要优化 IndexLookUp

1. **看 estRows**：回表行数 < 几百行，IndexLookUp 通常可接受
2. **看 EXPLAIN ANALYZE**：关注 Probe 阶段的 `exec info` 耗时，Probe >> Build 说明回表是瓶颈
3. **看查询列**：如果查询列是固定的几个，建立联合覆盖索引通常是最优解
4. **看业务频率**：高频查询即使每行回表很快，累积开销也不可忽略

:::

## 常见问题

**Q: TiDB 中为什么有时 IndexLookUp 的 estRows 和实际行数差很多？**

A: `estRows` 基于统计信息（`ANALYZE TABLE` 采集），如果统计信息不准确（如大量写入后未更新），预估行数会偏差。用 `EXPLAIN ANALYZE` 查看 `actRows` 获取实际行数。

**Q: Cluster Index 和普通主键在 TiDB 中有区别吗？**

A: TiDB 中所有主键默认就是聚簇索引（等同于 MySQL InnoDB）。显式声明 `/* CLUSTERED */` 主要用于与非聚簇索引（如某些 KV 场景的主键设计）区分，在常规表使用中两者行为一致。

**Q: 建立覆盖索引会不会增加太多存储开销？**

A: 覆盖索引本质是冗余存储——将查询需要的列也放入索引叶子节点。以 `idx_city_name(city, name)` 为例，索引中额外存储了 `name` 列。需要权衡查询加速收益 vs 存储和写入开销。高频查询且回表行数多（> 数千行）时，收益远大于成本。
