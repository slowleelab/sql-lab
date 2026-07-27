# EXPLAIN 参考结果 - bad.sql（TiKV 行存聚合）

## TiDB v7.5+（50 万行 t_sales，无 TiFlash 副本，MPP 关闭）

---

### 聚合查询：TiKV 行存 + 无 MPP

```sql
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

```
+---------------------------------+----------+-----------+-----------------------------+-------------------------------------------------------------------+
| id                              | estRows  | task      | access object               | operator info                                                     |
+---------------------------------+----------+-----------+-----------------------------+-------------------------------------------------------------------+
| Sort_10                         | 60.00    | root      |                             | t_sales.total_amount:desc                                         |
| └─Projection_12                 | 60.00    | root      |                             | t_sales.category, t_sales.region, Column#13, Column#14, Column#15, Column#16 |
|   └─HashAgg_14                  | 60.00    | root      |                             | group by:t_sales.category, t_sales.region, funcs:count(1)->Column#13, funcs:sum(t_sales.amount)->Column#14, funcs:sum(t_sales.qty)->Column#15, funcs:avg(t_sales.amount)->Column#16 |
|     └─TableReader_15            | 250000.00| root      |                             | data:Selection_16                                                |
|       └─Selection_16            | 250000.00| cop[tikv] |                             | ge(t_sales.sale_date, 2026-01-01), le(t_sales.sale_date, 2026-06-30) |
|         └─TableFullScan_17      | 500000.00| cop[tikv] | table:t_sales               | keep order:false                                                 |
+---------------------------------+----------+-----------+-----------------------------+-------------------------------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| TableFullScan_17 task | `cop[tikv]` | 全表扫描在 TiKV 执行，扫描 50 万行 |
| Selection_16 task | `cop[tikv]` | WHERE 过滤在 TiKV 层完成，返回约 25 万行（半年数据） |
| HashAgg_14 task | **`root`** | **聚合在 TiDB Server 层完成**，数据从 TiKV 传到 TiDB 层汇总 |
| 数据传输 | ~25 万行原始数据 | TiKV 将过滤后的行存数据通过网络传给 TiDB |
| 聚合方式 | HashAgg(root) | 单节点聚合，无分布式并行 |

### 为什么慢

行存（TiKV）上的聚合查询执行流程：

1. **TableFullScan_17（cop[tikv]）**：TiKV 扫描 t_sales 全表 50 万行数据
2. **Selection_16（cop[tikv]）**：TiKV 本地过滤 sale_date 范围，保留约 25 万行（半年数据）
3. **TableReader_15（root）**：25 万行数据从 TiKV 通过网络传输到 TiDB Server（**关键瓶颈**）
4. **HashAgg_14（root）**：TiDB Server 单节点在内存中对 25 万行做 GROUP BY 聚合
5. **Sort_10（root）**：TiDB Server 对聚合结果排序

**核心问题**：
- 所有数据以行存格式从 TiKV 传输 —— 行存包含完整列，即使聚合只需要 category、region、amount、qty 四列
- 聚合在 TiDB Server 单节点完成 —— 无法利用多节点分布式计算能力
- 大表场景下（百万、千万行），单节点聚合的内存和 CPU 成为瓶颈

### TiFlash 副本状态（无副本）

```
-- SELECT * FROM information_schema.tiflash_replica WHERE table_schema = 'sql_treasure';
-- 返回空结果：当前 t_sales 表没有 TiFlash 副本，所有查询只能走 TiKV 行存
```

---

## 行存（TiKV）聚合查询的瓶颈总结

| 特征 | 表现 |
|------|------|
| 扫描方式 | TiKV TableFullScan，全表行存扫描 |
| WHERE 过滤 | 在 TiKV cop[tikv] 完成 |
| 聚合位置 | **TiDB Server（root）** — 单节点聚合 |
| 数据传输量 | 约 25 万行，行存格式（含全部列） |
| 并行能力 | 无分布式并行，聚合在单节点执行 |
| 列存优势 | 无（行存传输所有列） |
| 适用场景 | OLTP 点查、小范围扫描、事务操作 |
| 不适用场景 | OLAP 大表聚合、BI 报表、数据分析 |
