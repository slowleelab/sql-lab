# EXPLAIN 参考结果 - good.sql（Dynamic Pruning 分区裁剪生效）

## TiDB（50 万行订单数据，RANGE 分区按年）

### 1. RANGE 分区裁剪 —— 只访问 p2025 分区

```
SET SESSION tidb_partition_prune_mode = 'dynamic';

EXPLAIN SELECT COUNT(*), SUM(amount) FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';

+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
| id                       | estRows     | task         | access object         | operator info                             |
+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
| HashAgg_9                | 1.00        | root         |                       | funcs:count(1)->Column#7, funcs:sum(amount)->Column#8 |
| └─TableReader_10         | 166666.67   | root         | partition:p2025       | data:HashAgg_5                             |
|   └─HashAgg_5            | 166666.67   | cop[tikv]    |                       | funcs:count(1), funcs:sum(amount)          |
|     └─Selection_8        | 166666.67   | cop[tikv]    |                       | ge(order_date, 2025-01-01), le(order_date, 2025-12-31) |
|       └─TableFullScan_7  | 166666.67   | cop[tikv]    | table:t_order_range   | keep order:false                     |
+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| access object | `partition:p2025` | 仅访问 p2025 分区，裁剪成功 |
| estRows | 166,666 | 仅估算 p2025 分区内的行数（约 1/3） |
| TableFullScan | 166,666 | 相比 bad.sql 的 500,000，扫描量减少 2/3 |

### 2. 精确单日查询 —— 只访问 p2025 分区

```
EXPLAIN SELECT * FROM t_order_range WHERE order_date = '2025-06-15';

+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
| id                         | estRows | task         | access object         | operator info                            |
+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
| IndexLookUp_10             | 10.00   | root         | partition:p2025       |                                        |
| ├─IndexRangeScan_8(Build)  | 10.00   | cop[tikv]    | table:t_order_range   | range:[2025-06-15,2025-06-15], index:idx_order_date |
|   │                        |         |              |                       | partition:p2025                         |
| └─TableRowIDScan_9(Probe)  | 10.00   | cop[tikv]    | table:t_order_range   | keep order:false, partition:p2025       |
+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
```

`access object` 列明确显示 `partition:p2025`，优化器在 Dynamic Pruning 下精确裁剪到单个分区。配合 `idx_order_date` 索引，做到了"分区裁剪 + 索引精确查找"的双重优化。

### 3. 跨分区查询 —— 裁剪到两个分区

```
EXPLAIN SELECT COUNT(*), SUM(amount) FROM t_order_range
WHERE order_date BETWEEN '2025-06-01' AND '2025-08-31';

+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
| id                       | estRows     | task         | access object         | operator info                             |
+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
| HashAgg_9                | 1.00        | root         |                       | funcs:count(1)->Column#7, funcs:sum(amount)->Column#8 |
| └─TableReader_10         | 41666.67    | root         | partition:p2025       | data:HashAgg_5                             |
|   └─HashAgg_5            | 41666.67    | cop[tikv]    |                       | funcs:count(1), funcs:sum(amount)          |
|     └─Selection_8        | 41666.67    | cop[tikv]    |                       | ge(order_date, 2025-06-01), le(order_date, 2025-08-31) |
|       └─TableFullScan_7  | 41666.67    | cop[tikv]    | table:t_order_range   | keep order:false                     |
+--------------------------+-------------+--------------+-----------------------+----------------------------------------------+
```

三个月的范围仍在同年内（2025 年），优化器裁剪到 `partition:p2025`，扫描量进一步减少。

### 4. HASH 分区单值查询 —— 精确裁剪到单个分区

```
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;

+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
| id                         | estRows | task         | access object         | operator info                            |
+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
| IndexLookUp_10             | 10.00   | root         | partition:p3          |                                        |
| ├─IndexRangeScan_8(Build)  | 10.00   | cop[tikv]    | table:t_order_hash    | range:[12345,12345], index:idx_user_id   |
|   │                        |         |              |                       | partition:p3                            |
| └─TableRowIDScan_9(Probe)  | 10.00   | cop[tikv]    | table:t_order_hash    | keep order:false, partition:p3          |
+----------------------------+---------+--------------+-----------------------+---------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| access object | `partition:p3` | HASH 分区裁剪到 p3（user_id=12345 的 hash 结果） |
| IndexRangeScan | range:[12345,12345] | 走索引 + 分区裁剪的双重优化 |
| estRows | 10.00 | 估算每个分区内约 10 行匹配 |

User_id = 12345，经过 `HASH(user_id) % 8` 计算后只落入 p3 分区，Dynamic Pruning 精确裁剪只扫描 p3。

### 5. 对比 Static Pruning（旧模式）

```
SET SESSION tidb_partition_prune_mode = 'static';

EXPLAIN SELECT COUNT(*), SUM(amount) FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';

+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| id                       | estRows     | task         | access object  | operator info                             |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| HashAgg_9                | 1.00        | root         |                | funcs:count(1)->Column#7, funcs:sum(amount)->Column#8 |
| └─TableReader_10         | 166666.67   | root         | partition:p2025 | data:HashAgg_5                           |
|   └─HashAgg_5            | 166666.67   | cop[tikv]    |                | funcs:count(1), funcs:sum(amount)          |
|     └─Selection_8        | 166666.67   | cop[tikv]    |                | ge(order_date, 2025-01-01), le(order_date, 2025-12-31) |
|       └─TableFullScan_7  | 166666.67   | cop[tikv]    | table:t_order_range | keep order:false                     |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
```

Static Pruning 在简单范围条件下也能裁剪，但 `access object` 列的显示可能不如 Dynamic 模式直观。关键区别在于：Static Pruning 是在优化阶段生成多个子计划（每个分区一个），而 Dynamic Pruning 在执行阶段直接构建单个计划并动态决定分区范围。

## 为什么 Dynamic Pruning 更快

### Dynamic vs Static Pruning 架构对比

```
Static Pruning（v5.x 默认，v6.x+ 已废弃）:
  SQL 解析 → 优化器为每个分区生成独立计划
              ├─ Plan_p2024 (TABLE SCAN p2024)
              ├─ Plan_p2025 (TABLE SCAN p2025)
              ├─ Plan_p2026 (TABLE SCAN p2026)
              └─ ...
              ↓ UNION ALL 合并
              → 每个分区计划都是独立的 TableReader（多次 RPC）

Dynamic Pruning（v6.x+ 默认）:
  SQL 解析 → 优化器生成统一计划 → 参数绑定后动态决定分区列表
              ↓
              单次 TableReader 访问 [p2024, p2025, p2026, ...]
              ↓
              TiKV 内部并行扫描多个分区
              → 一次 RPC，内部并行
```

### Dynamic Pruning 三重优势

1. **减少 RPC 次数**：Static 模式下每个分区需要一次独立的 RPC 请求；Dynamic 模式下一次请求覆盖所有目标分区
2. **支持参数化查询**：Prepare/Execute 下，Static Pruning 无法感知具体参数值（优化阶段参数未绑定），Dynamic Pruning 在参数绑定后裁剪，Plan Cache 友好
3. **分区数弹性**：Static 模式下分区越多计划越复杂（计划大小 O(n)），Dynamic 模式下计划大小 O(1)

### 优化效果量化

| 场景 | bad.sql（全分区扫描 50万行） | good.sql（Dynamic Pruning，单分区 ~16.6万行） | 提升 |
|------|---------------------------|----------------------------------------------|------|
| 扫描行数 | 500,000 | 166,666 | 减少 67% |
| RPC 次数 | 5 次（每个分区一次） | 1 次 | 减少 80% |
| 计划大小 | 大（多分区 UNION ALL） | 小（统一计划） | Plan Cache 友好 |
| 内存占用 | 高 | 低 | ~ |

## TiDB 特有优化：分区与 Region 分布

TiDB 的分区表每个分区对应独立的 Region 组：

```
t_order_range
  ├── p2024 → Region [100, 200)  ← TiKV Node 1
  ├── p2025 → Region [200, 300)  ← TiKV Node 2
  ├── p2026 → Region [300, 400)  ← TiKV Node 3
  ├── p2027 → Region [400, 500)  ← TiKV Node 1
  └── p_future → Region [500, 600) ← TiKV Node 2
```

- 分区裁剪 = 跳过无关 Region，减少 KV 读取请求
- 不同分区的 Region 分布在不同 TiKV 节点上，天然实现数据分散和并行读取
- 热点分区问题：如果所有查询集中在 p2025，p2025 对应的 Region 可能成为热点

使用 `SHOW TABLE t_order_range REGIONS;` 可以查看每个分区对应的 Region 分布情况。
