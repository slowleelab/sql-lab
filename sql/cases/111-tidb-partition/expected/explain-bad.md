# EXPLAIN 参考结果 - bad.sql（分区裁剪未生效或低效）

## TiDB（50 万行订单数据，RANGE 分区按年）

### 1. RANGE 分区查询 —— 可能全分区扫描

```
EXPLAIN SELECT COUNT(*), SUM(amount) FROM t_order_range
WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01';

+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| id                       | estRows     | task         | access object  | operator info                             |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| HashAgg_9                | 1.00        | root         |                | funcs:count(1)->Column#7, funcs:sum(amount)->Column#8 |
| └─TableReader_10         | 166666.67   | root         | partition:all  | data:HashAgg_5                             |
|   └─HashAgg_5            | 166666.67   | cop[tikv]    |                | funcs:count(1), funcs:sum(amount)          |
|     └─Selection_8        | 166666.67   | cop[tikv]    |                | ge(order_date, 2025-01-01), lt(order_date, 2026-01-01) |
|       └─TableFullScan_7  | 500000.00   | cop[tikv]    | table:t_order_range | keep order:false                     |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
```

### 2. 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| access object | `partition:all` | 访问了所有分区，未发生裁剪 |
| estRows | 500,000 → 166,666 | 全表扫描 50 万行后过滤 |
| task | cop[tikv] | 下推到 TiKV 协处理器执行 |

**未发生分区裁剪的原因**：
- 如果 `tidb_partition_prune_mode = 'static'`（旧版本默认），某些范围条件可能无法精确裁剪
- Static Pruning 在优化阶段决定访问哪些分区，对复杂表达式支持有限
- 大量的 `TableFullScan` 说明每个分区都做了全扫描

### 3. HASH 分区表 —— 单 user_id 查询

```
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;

+---------------------------+---------+--------------+-----------+------------------------------------+
| id                        | estRows | task         | access object  | operator info                 |
+---------------------------+---------+--------------+-----------+------------------------------------+
| TableReader_7             | 10.00   | root         | partition:all | data:Selection_6              |
| └─Selection_6             | 10.00   | cop[tikv]    |                | eq(user_id, 12345)            |
|   └─TableFullScan_5       | 500000.00 | cop[tikv]  | table:t_order_hash | keep order:false        |
+---------------------------+---------+--------------+-----------+------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| access object | `partition:all` | HASH 分区未裁剪，8 个分区全扫描 |
| type | TableFullScan | 每个分区全表扫描 |
| estRows | 10.00 | 优化器估算返回约 10 行 |

HASH 分区的裁剪前提是分区键的条件能让优化器推断出目标分区。Static Pruning 下只有 `user_id = 12345` 的等值条件可以裁剪——但需要确认 `tidb_partition_prune_mode` 是否为 dynamic。

### 4. 跨用户范围查询 —— 所有分区都参与

```
EXPLAIN SELECT COUNT(*), SUM(amount) FROM t_order_hash
WHERE user_id BETWEEN 10000 AND 20000;

+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| id                       | estRows     | task         | access object  | operator info                             |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
| HashAgg_9                | 1.00        | root         |                | funcs:count(1)->Column#7, funcs:sum(amount)->Column#8 |
| └─TableReader_10         | 100000.00   | root         | partition:all | data:HashAgg_5                             |
|   └─HashAgg_5            | 100000.00   | cop[tikv]    |                | funcs:count(1), funcs:sum(amount)          |
|     └─Selection_8        | 100000.00   | cop[tikv]    |                | ge(user_id, 10000), le(user_id, 20000)     |
|       └─TableFullScan_7  | 500000.00   | cop[tikv]    | table:t_order_hash | keep order:false                     |
+--------------------------+-------------+--------------+-----------+----------------------------------------------+
```

HASH 分区按 `user_id % 8` 分布，范围条件 `BETWEEN 10000 AND 20000` 会覆盖多个哈希槽，所有 8 个分区都需要扫描。

## TiDB vs MySQL 分区差异表

| 维度 | TiDB (Dynamic Pruning) | TiDB (Static Pruning) | MySQL 8.0 |
|------|----------------------|----------------------|-----------|
| 裁剪时机 | 执行阶段动态决定 | 优化阶段静态决定 | 优化阶段（与 TiDB static 类似） |
| RANGE 裁剪 | 精确，支持复杂条件 | 仅支持简单范围 | 精确 |
| HASH 裁剪 | 等值条件精确裁剪 | 等值条件可裁剪 | 等值条件精确裁剪 |
| LIST 裁剪 | 精确 | 精确 | 精确 |
| 多分区查询 | 一次请求，内部并行 | 每个分区单独请求 | UNION ALL 方式 |
| access object | `partition:p0,p1,...` | 无此信息 | `partitions` 列显示 |

核心差异：Dynamic Pruning 将"决定访问哪些分区"推迟到执行阶段，避免了 Static Pruning 中因 estimate 不准导致的错误裁剪。当查询的 WHERE 条件包含变量或复杂表达式时，Static Pruning 可能保守地选择全分区扫描，而 Dynamic Pruning 可以等参数绑定后再精确裁剪。
