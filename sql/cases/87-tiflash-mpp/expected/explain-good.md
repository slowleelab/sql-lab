# EXPLAIN 参考结果 - good.sql（TiFlash 列存 + MPP 分布式聚合）

## TiDB v7.5+（50 万行 t_sales，已创建 TiFlash 副本，MPP 开启）

---

### 前置操作：创建 TiFlash 副本

```sql
-- 为 t_sales 表创建 1 个 TiFlash 副本
ALTER TABLE t_sales SET TIFLASH REPLICA 1;

-- 等待副本同步完成（available = 1 表示已就绪）
SELECT * FROM information_schema.tiflash_replica
WHERE table_schema = 'sql_treasure' AND available = 1;
```

### 聚合查询：TiFlash 列存 + MPP 分布式执行

```sql
SET SESSION tidb_enforce_mpp = ON;
SET SESSION tidb_allow_mpp = ON;

EXPLAIN SELECT category, region, COUNT(*) AS orders,
    SUM(amount) AS total_amount, SUM(qty) AS total_qty,
    AVG(amount) AS avg_amount
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;
```

```
+--------------------------------------+----------+--------------+-----------------------------+-------------------------------------------------------------------+
| id                                   | estRows  | task         | access object               | operator info                                                     |
+--------------------------------------+----------+--------------+-----------------------------+-------------------------------------------------------------------+
| TableReader_55                       | 60.00    | root         |                             | MPPVersion: 2, data:ExchangeSender_54                             |
| └─ExchangeSender_54                  | 60.00    | mpp[tiflash] |                             | ExchangeType: PassThrough                                         |
|   └─Projection_14                    | 60.00    | mpp[tiflash] |                             | t_sales.category, t_sales.region, Column#13, Column#14, Column#15, Column#16 |
|     └─Sort_13                        | 60.00    | mpp[tiflash] |                             | Column#14:desc                                                    |
|       └─HashAgg_23                   | 60.00    | mpp[tiflash] |                             | group by:t_sales.category, t_sales.region, funcs:count(1)->Column#13, funcs:sum(t_sales.amount)->Column#14, funcs:sum(t_sales.qty)->Column#15, funcs:avg(t_sales.amount)->Column#16 |
|         └─ExchangeReceiver_25        | 100.00   | mpp[tiflash] |                             |                                                                   |
|           └─ExchangeSender_24        | 100.00   | mpp[tiflash] |                             | ExchangeType: HashPartition, Hash Cols: [name: t_sales.category, name: t_sales.region] |
|             └─HashAgg_22             | 100.00   | mpp[tiflash] |                             | group by:t_sales.category, t_sales.region, funcs:count(Column#18)->Column#13, funcs:sum(Column#19)->Column#14, funcs:sum(Column#20)->Column#15, funcs:sum(Column#21)->Column#17 |
|               └─Projection_29        | 250000.00| mpp[tiflash] |                             | t_sales.category, t_sales.region, t_sales.amount, t_sales.qty     |
|                 └─TableFullScan_28   | 500000.00| mpp[tiflash] | table:t_sales               | pushed down filter:ge(t_sales.sale_date, 2026-01-01), le(t_sales.sale_date, 2026-06-30), keep order:false |
+--------------------------------------+----------+--------------+-----------------------------+-------------------------------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| TableFullScan_28 task | **`mpp[tiflash]`** | 扫描在 TiFlash 节点执行，列存扫描 |
| WHERE 下推 | `pushed down filter` | sale_date 过滤条件下推到 TiFlash，列存只读需要的列 |
| 两阶段 HashAgg | **HashAgg_22（局部聚合）+ HashAgg_23（最终聚合）** | MPP 两阶段聚合：先在 TiFlash 节点本地预聚合，再按 category, region 哈希重分布后最终聚合 |
| ExchangeSender_24 | `ExchangeType: HashPartition` | 按 category + region 哈希分片，数据在 TiFlash 节点间交换 |
| ExchangeReceiver_25 | `mpp[tiflash]` | 接收其他 TiFlash 节点发来的分片数据 |
| Sort_13 task | `mpp[tiflash]` | 排序也在 TiFlash MPP 中分布式执行 |
| 所有算子 task | **全部 `mpp[tiflash]`** | 除最终的 TableReader_55，全链路在 TiFlash MPP 中分布式执行 |

### 为什么快

TiFlash 列存 + MPP 的查询执行流程：

1. **TableFullScan_28（mpp[tiflash]）**：TiFlash 节点扫描 t_sales 列存副本，只读取需要的 4 列（category、region、amount、qty）。列存天然跳过不需要的列（id、product_id、sale_date），且 WHERE 过滤条件下推
2. **Projection_29（mpp[tiflash]）**：仅计算和保留聚合需要的列
3. **HashAgg_22（mpp[tiflash]）**：第一阶段局部聚合 —— 每个 TiFlash 节点对本节点数据做 GROUP BY 预聚合
4. **ExchangeSender_24 + ExchangeReceiver_25**：M 按 category、region 哈希重分布，确保相同分组的数据汇聚到同一 TiFlash 节点
5. **HashAgg_23（mpp[tiflash]）**：第二阶段聚合 —— 收到其他节点的分片数据后做最终聚合
6. **Sort_13（mpp[tiflash]）**：按 total_amount 降序排序
7. **ExchangeSender_54 → TableReader_55**：最终结果返回 TiDB Server 展示

**核心优势**：
- **列存只读需要的列** —— 50 万行只需读 4 列（而非行存的 8 列），I/O 直接减半
- **MPP 分布式聚合** —— 多个 TiFlash 节点并行聚合，而非单节点 （root）聚合
- **两阶段聚合减少网络交换** —— 先本地预聚合再跨节点交换，交换数据量从 25 万行降低到约 60 组
- **数据在 TiFlash 间直接交换** —— 不经过 TiDB Server，消除中间传输瓶颈

---

## TiFlash MPP vs TiKV 行存对比

| 维度 | bad.sql（TiKV 行存） | good.sql（TiFlash + MPP） |
|------|---------------------|--------------------------|
| 存储格式 | 行存（所有列存一起） | 列存（按列独立存储） |
| 扫描方式 | TableFullScan(cop[tikv]) | TableFullScan(mpp[tiflash]) |
| 读取列数 | 全列（8 列） | 仅 4 列（列存按需读取） |
| 聚合位置 | TiDB Server(root) 单节点 | TiFlash MPP 多节点分布式 |
| 聚合阶段 | 1 阶段（单节点 HashAgg） | 2 阶段（本地预聚合 + 最终聚合） |
| 数据交换 | TiKV→TiDB 网络传输 | TiFlash 节点间 MPI 交换 |
| 数据传输量 | ~25 万行（行存全列） | ~60 组（两阶段聚合后） |
| 并行度 | 单节点 | 多 TiFlash 节点并行 |
| 预估加速 | 基准 | **10-50x**（取决于节点数、数据量） |

### MPP 相关变量说明

```sql
SHOW VARIABLES LIKE '%mpp%';
SHOW VARIABLES LIKE '%tiflash%';
```

| 变量 | 值 | 说明 |
|------|-----|------|
| `tidb_enforce_mpp` | ON | 强制优化器选择 MPP 模式（忽略成本估算） |
| `tidb_allow_mpp` | ON | 允许优化器生成 MPP 执行计划 |
| `tidb_isolation_read_engines` | tidb,tikv,tiflash | 允许查询使用的存储引擎列表 |
| `tidb_enable_tiflash` | ON | 是否允许使用 TiFlash 副本 |
