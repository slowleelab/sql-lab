# TiFlash 列存与 MPP 分析加速

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['TiFlash', 'MPP', '列存', 'HTAP']" />

## 500 万慢：TiDB 的报表查询越来越慢
TiDB 的报表查询越来越慢。业务跑在 TiKV 行存上，500 万行的 GROUP BY 聚合查询需要 10 秒以上，BI 团队抱怨"数据出不来"。表象是数据量大，但根因在于**行存（TiKV）不适合 OLAP 聚合查询** —— 每行数据包含所有列，聚合只需要 3-4 列却要传输全行，且单节点聚合无法利用分布式并行能力。

```sql
-- 典型的报表聚合查询，在 TiKV 上跑得很慢
SELECT category, region, COUNT(*) AS orders,
    SUM(amount) AS total_amount, SUM(qty) AS total_qty
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;
```

::: danger 真实场景
某电商平台的销售报表，t_sales 表 500 万行，按品类+区域做聚合统计。开发发现：同样的 SQL，在单机 MySQL 8.0 用列存引擎跑 1 秒，在 TiDB（仅 TiKV 行存）跑 12 秒。原因不是 TiDB 慢，而是 **TiKV 行存不适合做 OLAP** —— 行存的设计目标是 TP 事务（点查、小范围更新），不是 AP 分析（大范围聚合、全表扫描）。
:::

::: warning 核心认知
TiDB 是 HTAP 数据库，它有两套存储引擎：

- **TiKV（行存）**：面向 OLTP，数据按行存储，适合点查、事务、小范围扫描。聚合查询需要传输全行数据到 TiDB Server 层单节点计算。
- **TiFlash（列存）**：面向 OLAP，数据按列存储，只读需要的列。配合 MPP 引擎，聚合查询可以在多个 TiFlash 节点上分布式并行执行。

关键开关是两个 SESSION 变量：
- `tidb_allow_mpp`：是否允许优化器生成 MPP 计划
- `tidb_enforce_mpp`：是否强制使用 MPP（忽略成本比较）

当 EXPLAIN 中看到所有算子 `task=mpp[tiflash]`（而非 `cop[tikv]` 或 `root`），说明查询已走列存 + MPP 分布式执行路径。
:::

## 问题分析

### bad.sql（TiKV 行存 + 无 MPP）

```sql
-- 关闭 MPP，强制走 TiKV 行存
SET SESSION tidb_enforce_mpp = OFF;
SET SESSION tidb_allow_mpp = OFF;

EXPLAIN SELECT category, region, COUNT(*) AS orders,
    SUM(amount) AS total_amount, SUM(qty) AS total_qty,
    AVG(amount) AS avg_amount
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;
```

### EXPLAIN 结果（bad.sql）

```
+---------------------------------+----------+-----------+-----------------------------+----------------------------------+
| id                              | estRows  | task      | access object               | operator info                    |
+---------------------------------+----------+-----------+-----------------------------+----------------------------------+
| Sort_10                         | 60.00    | root      |                             | t_sales.total_amount:desc        |
| └─Projection_12                 | 60.00    | root      |                             | ...                              |
|   └─HashAgg_14                  | 60.00    | root      |                             | group by:category, region, ...   |
|     └─TableReader_15            | 250000.00| root      |                             | data:Selection_16                |
|       └─Selection_16            | 250000.00| cop[tikv] |                             | ge(sale_date, ...), le(...)      |
|         └─TableFullScan_17      | 500000.00| cop[tikv] | table:t_sales               | keep order:false                 |
+---------------------------------+----------+-----------+-----------------------------+----------------------------------+
```

### 为什么慢

行存（TiKV）聚合查询的执行流程：

1. **TableFullScan_17（cop[tikv]）**：TiKV 扫描 t_sales 全表 50 万行，行存格式读取所有 8 列（id、product_id、category、region、amount、qty、sale_date、主键）
2. **Selection_16（cop[tikv]）**：TiKV 本地过滤 sale_date 范围，保留约 25 万行（半年数据）
3. **TableReader_15（root）**：25 万行完整数据（行存全列）从 TiKV 跨越网络传输到 TiDB Server —— **关键瓶颈**
4. **HashAgg_14（root）**：TiDB Server 单节点在内存中对 25 万行做 GROUP BY 聚合
5. **Sort_10（root）**：TiDB Server 对聚合结果排序

**核心问题**：

- **行存传输全列**：聚合只需要 category、region、amount、qty 四列，但行存以行为单位，必须传输全部 8 列。每行多传输了 id、product_id、sale_date 三列（即 60% 以上的无效数据）
- **单节点聚合**：HashAgg 在 TiDB Server 单节点（root）完成，无论集群有多少 TiFlash 节点都无法并行加速
- **内存压力**：25 万行数据在 TiDB Server 内存中做 HASH GROUP BY，消耗大量内存

当数据量从 50 万增长到 500 万、5000 万时，这三个问题线性放大，查询耗时从秒级恶化到分钟级。

## 优化方案

### good.sql（TiFlash 列存 + MPP 分布式）

```sql
-- 1. 创建 TiFlash 副本（需在集群有 TiFlash 节点的前提下）
-- ALTER TABLE t_sales SET TIFLASH REPLICA 1;
-- 等待副本同步完成
-- SELECT * FROM information_schema.tiflash_replica
-- WHERE table_schema = 'sql_treasure' AND available = 1;

-- 2. 启用 MPP 模式
SET SESSION tidb_enforce_mpp = ON;
SET SESSION tidb_allow_mpp = ON;

-- 3. 同样的查询，走 MPP + TiFlash 列存
EXPLAIN SELECT category, region, COUNT(*) AS orders,
    SUM(amount) AS total_amount, SUM(qty) AS total_qty,
    AVG(amount) AS avg_amount
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;
```

### EXPLAIN 结果（good.sql）

```
+--------------------------------------+----------+--------------+-----------------------------+----------------------------------+
| id                                   | estRows  | task         | access object               | operator info                    |
+--------------------------------------+----------+--------------+-----------------------------+----------------------------------+
| TableReader_55                       | 60.00    | root         |                             | MPPVersion: 2, ...               |
| └─ExchangeSender_54                  | 60.00    | mpp[tiflash] |                             | ExchangeType: PassThrough        |
|   └─Projection_14                    | 60.00    | mpp[tiflash] |                             | ...                              |
|     └─Sort_13                        | 60.00    | mpp[tiflash] |                             | Column#14:desc                   |
|       └─HashAgg_23                   | 60.00    | mpp[tiflash] |                             | group by:category, region, ...   |
|         └─ExchangeReceiver_25        | 100.00   | mpp[tiflash] |                             |                                  |
|           └─ExchangeSender_24        | 100.00   | mpp[tiflash] |                             | HashPartition(category, region)  |
|             └─HashAgg_22             | 100.00   | mpp[tiflash] |                             | group by:category, region, ...   |
|               └─Projection_29        | 250000.00| mpp[tiflash] |                             | category, region, amount, qty    |
|                 └─TableFullScan_28   | 500000.00| mpp[tiflash] | table:t_sales               | pushed down filter:ge(...), ...  |
+--------------------------------------+----------+--------------+-----------------------------+----------------------------------+
```

### 原理

TiFlash + MPP 模式下，查询引擎从"TiKV 运输 + TiDB 单节点计算"变为"TiFlash 本机计算 + 节点间 MPI 交换"：

1. **列存只读需要的列**：TableFullScan_28 在 TiFlash 节点扫描列存副本，只读取 category、region、amount、qty 四列。列存天然跳过 id、product_id、sale_date 等不需要的列，I/O 直接减少一半以上

2. **第一阶段局部聚合（HashAgg_22）**：每个 TiFlash 节点对本节点上的数据执行 GROUP BY 预聚合。假如有 4 个 TiFlash 节点，每个节点处理约 12.5 万行

3. **MPP 数据交换（ExchangeSender_24 + ExchangeReceiver_25）**：按 category 和 region 做 HashPartition 重分布，确保相同（category, region）组合的数据汇聚到同一 TiFlash 节点

4. **第二阶段最终聚合（HashAgg_23）**：每个 TiFlash 节点收到其他节点发来的分片数据后，执行最终聚合。因为第一阶段已经预聚合，交换的数据量从 ~25 万行骤降到 ~60 组（6 category x 10 region）

5. **分布式排序（Sort_13）**：排序也在 MPP 中分布式执行

6. **结果返回（ExchangeSender_54 → TableReader_55）**：最终 60 行结果通过 TiDB Server 返回客户端

#### 两阶段聚合的关键价值

MPP 的两阶段 HashAgg 是性能提升的核心：

| 阶段 | 输入数据量 | 输出数据量 | 执行位置 |
|------|----------|----------|---------|
| 第一阶段 HashAgg_22 | ~25 万行（本地分片） | ~60 组（每个节点最多 60 组） | 各 TiFlash 节点本地 |
| 数据交换 | ~60 组 x 节点数 | ~60 组 x 节点数 | TiFlash 节点间 MPI |
| 第二阶段 HashAgg_23 | ~60 组 x 节点数 | ~60 组 | 各 TiFlash 节点本地 |

**如果没有两阶段聚合**，需要交换 25 万行原始数据。两阶段聚合后，交换的数据量骤降到约 240 行（4 节点 x 60 组），**网络交换量减少了 1000 倍**。

### 对比

| | bad.sql（TiKV 行存） | good.sql（TiFlash + MPP） |
|---|---|---|
| 存储引擎 | TiKV 行存 | TiFlash 列存 |
| 扫描 task | cop[tikv] | mpp[tiflash] |
| 读取列数 | 8 列（行存全列） | 4 列（列存按需） |
| 聚合 task | **root**（TiDB Server 单节点） | **mpp[tiflash]**（多节点分布式） |
| 聚合阶段 | 1 阶段 | 2 阶段（局部 + 最终） |
| 数据交换 | TiKV → TiDB 网络 25 万行 | TiFlash 节点间 MPI ~240 行 |
| 排序 | root（TiDB） | mpp[tiflash] |
| 并行度 | 1 个 TiDB Server 节点 | N 个 TiFlash 节点并行 |
| 预估加速比 | 基准 | **10-50x**（取决于节点数、数据量） |

<ExplainCompare
  :bad="{ task: 'root', type: 'HashAgg(root) + TableFullScan(cop[tikv])', estRows: '250,000（传输行数）', Extra: '行存全列传输，单节点聚合，网络瓶颈' }"
  :good="{ task: 'mpp[tiflash]', type: '两阶段 HashAgg + TableFullScan(mpp[tiflash])', estRows: '~240（交换行数）', Extra: '列存按需读取，分布式并行聚合，交换量减 1000 倍' }"
  improvement="列存 I/O 减半 + MPP 并行聚合 + 两阶段聚合将网络交换量从 25 万行降至 ~240 行，总计加速 10-50 倍"
/>

## 避坑指南

::: warning 注意事项

1. **TiFlash 副本需要额外存储空间**。每个 TiFlash 副本会占用与 TiKV 副本相当的磁盘空间（列存压缩后通常更小，但仍是一份独立副本）。规划集群存储时要预留 TiFlash 空间。

2. **TiFlash 副本同步需要时间**。创建副本后，数据从 TiKV 同步到 TiFlash 需要一定时间。数据量大时可能需要数小时。务必等待 `available = 1` 再测试：
   ```sql
   SELECT * FROM information_schema.tiflash_replica
   WHERE table_schema = 'sql_treasure' AND available = 1;
   ```

3. **小查询不适合 MPP**。MPP 有调度和网络交换开销。对于扫描几千行的小查询，TiKV 行存 + coprocessor 下推可能比 MPP 更快。TiDB 优化器会根据成本自动选择，一般不需要手动干预。仅在优化器选错时才用 `tidb_enforce_mpp` 强制。

4. **MPP 模式下的 EXPLAIN ANALYZE 是利器**。`EXPLAIN ANALYZE` 可以显示每个 MPP 算子的实际耗时和行数，帮助诊断分布式执行中的性能瓶颈：
   ```sql
   EXPLAIN ANALYZE SELECT ...
   ```

5. **不是所有 SQL 都支持 MPP**。以下场景会退化为 TiKV 行存或 TiDB root 执行：
   - 包含 `SELECT ... FOR UPDATE` 的查询
   - 部分不兼容的函数和表达式
   - 临时表
   - 部分系统变量的限制

   可以通过 EXPLAIN 输出确认：如果看到 `mpp[tiflash]` 说明已走 MPP。

6. **TiFlash 节点数量和副本数**。至少需要 1 个 TiFlash 节点 + 1 个副本。生产环境建议至少 2 个 TiFlash 节点，并设置 `TIFLASH REPLICA 2` 以实现高可用和并行加速。

7. **列存对 UPDATE/DELETE 不友好**。TiFlash 是列存，写入路径仍走 TiKV（行存），TiFlash 通过 Raft Learner 异步同步数据。因此 OLTP 写入性能不受 TiFlash 影响，但 TiFlash 数据有同步延迟（通常毫秒到秒级）。

:::

## TiKV vs TiFlash 选型指南

TiDB 的 HTAP 架构允许同一张表同时存在 TiKV（行存）和 TiFlash（列存）副本，优化器自动根据查询类型选择存储引擎。

### 选型对照表

| 维度 | TiKV（行存） | TiFlash（列存） |
|------|------------|---------------|
| 存储格式 | 行式存储 | 列式存储 |
| 主要用途 | OLTP（事务处理） | OLAP（分析查询） |
| 适合查询 | 点查、小范围扫描、索引回表、事务 | 大范围聚合、全表扫描、BI 报表 |
| 不适合场景 | 大表 GROUP BY / JOIN 聚合 | 高频点查、UPDATE/DELETE、事务 |
| 数据压缩 | 一般 | 列存压缩率高（通常 3-5x） |
| 副本同步 | Leader（实时） | Raft Learner（异步，毫秒-秒级延迟） |
| 执行引擎 | Coprocessor（cop[tikv]） | MPP（mpp[tiflash]） |
| 索引加速 | 支持（主键、二级索引） | 列存天然不需要索引（只读必要列） |
| 可扩展性 | TiKV 节点横向扩展 | TiFlash 节点横向扩展，MPP 并行计算 |

### 查询自动路由机制

TiDB 优化器在生成执行计划时，会根据以下因素自动选择 TiKV 还是 TiFlash：

1. **查询类型分析**：聚合查询（SUM、COUNT、AVG、GROUP BY）、大范围扫描 → 倾向 TiFlash；点查、小范围索引扫描 → 倾向 TiKV
2. **成本估算**：优化器估计两种路径的代价，选择代价更低的
3. **是否强制指定**：`tidb_enforce_mpp = ON` 强制走 TiFlash MPP
4. **副本可用性**：TiFlash 副本未同步完成时，自动 fallback 到 TiKV

```sql
-- 查看 TiFlash 副本状态
SELECT * FROM information_schema.tiflash_replica;

-- 查询当前走的存储引擎
EXPLAIN SELECT ...;
-- 观察 task 列: cop[tikv] = TiKV 行存, mpp[tiflash] = TiFlash 列存 + MPP
```

### 典型使用场景推荐

| 业务场景 | 推荐引擎 | 原因 |
|---------|:------:|------|
| 订单创建 / 修改 | TiKV | 事务写入，行存最优 |
| 根据订单 ID 查详情 | TiKV | 点查，主键索引直达 |
| 用户实时余额查询 | TiKV | 高频点查，需要最新数据 |
| 当日销售报表 | TiKV（小范围） | 数据量小，TiKV 足够 |
| 月度/季度经营分析 | **TiFlash** | 大范围聚合，列存 + MPP 加速明显 |
| BI 多维分析 | **TiFlash** | 多维度 GROUP BY + 聚合 |
| 实时大屏/看板 | **TiFlash** | 秒级刷新，大表聚合 |
| 数据导出 / 离线分析 | **TiFlash** | 全表扫描，列存 I/O 小 |

## 本地复现

```bash
# 默认在 TiDB 上运行
./scripts/run-case.sh 87-tiflash-mpp --ver tidb

# 跳过造数据重跑
./scripts/run-case.sh 87-tiflash-mpp --ver tidb --no-seed
```

::: warning 前提条件

本案例需要在具有 **TiFlash 节点** 的 TiDB 集群上运行。如果集群只有 TiKV 没有 TiFlash：

- **测试 bad.sql**：TiKV 行存聚合可以正常运行，观察 EXPLAIN 输出
- **测试 good.sql**：需要先部署 TiFlash 节点并创建副本
  ```bash
  # 使用 tiup 扩容 TiFlash 节点（生产环境）
  tiup cluster scale-out <cluster-name> tiflash_servers.yaml
  ```

对于没有 TiFlash 环境的本地测试，推荐使用 TiDB Playground 快速体验：
```bash
# 启动带 TiFlash 的本地集群
tiup playground nightly --tiflash 1 --tiflash.node 1
```

在 TiDB Cloud 或自建集群上，可以这样创建 TiFlash 副本：
```sql
-- 为指定表创建 1 个 TiFlash 副本
ALTER TABLE t_sales SET TIFLASH REPLICA 1;

-- 等待副本同步完成（PROGRESS = 1 表示已完成）
SELECT * FROM information_schema.tiflash_replica
WHERE table_schema = 'sql_treasure';
```

:::
