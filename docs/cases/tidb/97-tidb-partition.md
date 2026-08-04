# TiDB 分区表优化

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['分区表', 'Partition', 'Pruning', 'RANGE', 'HASH', 'LIST', '分区裁剪', 'Dynamic Pruning']" />

## 5 秒：MySQL 迁移到 TiDB 后
某电商平台的订单查询系统从 MySQL 迁移到 TiDB 后，运营人员反馈了一个奇怪的现象：**跨年订单统计查询（例如 "2025 年全年订单汇总"）响应时间在 3-5 秒，但单月订单查询（例如 "2025 年 6 月订单"）只需要 0.3 秒**。相同的数据集、相同的 SQL 模式，只因为时间范围不同，性能差了 10 倍以上。

运维排查后发现：
- 订单表 `t_order_range` 按 `YEAR(order_date)` 做了 RANGE 分区（p2024, p2025, p2026...），理论上查询 2025 年数据应该只扫描 p2025 分区
- 但 TiDB 的 `EXPLAIN` 输出显示 `access object: partition:all`——所有分区都被扫了
- 原因是 TiDB 集群从 v5.x 升级到 v6.x 后，`tidb_partition_prune_mode` 参数保持为 `static`（旧版默认），而未升级到默认的 `dynamic`

```sql
-- 看似简单的跨年查询，在 static pruning 下扫描所有分区
SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';
-- access object: partition:all  ← 未裁剪！
```

::: warning 真实场景

某 SaaS 平台迁移至 TiDB v6.5 后，运维保留了旧版 `static` pruning 配置以避免风险。结果月报表查询随着数据积累逐渐从 0.5 秒退化到 4 秒——因为每个月的查询都在扫描所有分区（p2023 + p2024 + p2025 + p2026...）。切换到 Dynamic Pruning 后，查询时间回到 0.3 秒，且随着分区增多性能保持稳定。

:::

**本质问题**：TiDB 的 partition pruning 模式决定了"决定访问哪些分区"的时机。Static Pruning 在优化阶段做出决策，对复杂条件保守处理；Dynamic Pruning 将决策推迟到执行阶段，能更精确地裁剪分区——但前提是配置正确。

## 问题分析

### TiDB 分区裁剪的两种模式

```
Static Pruning（v5.x 默认，v6.x+ 已不推荐）:
  优化阶段 → 对每个分区独立生成执行计划 → UNION ALL 合并
  优点: 执行计划清晰，每个分区的计划独立可分析
  缺点: 计划大小 O(n)，n=分区数；Prepare/Execute 下参数未知无法裁剪

Dynamic Pruning（v6.x+ 默认）:
  优化阶段 → 生成统一计划（分区信息作为参数） → 执行阶段动态决定分区列表
  优点: 计划大小 O(1)；支持参数化查询的精确裁剪；减少 RPC 次数
  缺点: 执行计划中看不到每个分区的独立计划细节（但不影响执行正确性）
```

### bad.sql：分区裁剪未生效的 4 个场景

```sql
-- 1. RANGE 分区查询 —— 可能触发 partition:all
EXPLAIN SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01';

-- 2. 检查修剪模式是否为 dynamic
SHOW VARIABLES LIKE 'tidb_partition_prune_mode';
-- static  → 需要切换为 dynamic

-- 3. HASH 分区单值查询 —— static 模式下可能无法裁剪
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;

-- 4. HASH 分区范围查询 —— 所有分区都要扫描
EXPLAIN SELECT COUNT(*), SUM(amount)
FROM t_order_hash
WHERE user_id BETWEEN 10000 AND 20000;
```

关键发现：

- **RANGE 分区**：理论上 `WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31'` 应该只命中 p2025，但 `tidb_partition_prune_mode = static` 时优化器可能保守地保留所有分区
- **HASH 分区**：`user_id = 12345` 只可能落在一个分区（`HASH(12345) % 8`），但 static pruning 下可能无法利用此信息
- **HASH 范围查询**：`BETWEEN 10000 AND 20000` 覆盖多个哈希值，裁剪收益有限，但 dynamic pruning 仍能优化 RPC 合并

### TiDB vs MySQL 分区差异表

| 维度 | TiDB (Dynamic Pruning) | TiDB (Static Pruning) | MySQL 8.0 |
|------|----------------------|----------------------|-----------|
| 裁剪时机 | 执行阶段动态决定 | 优化阶段静态决定 | 优化阶段（与 TiDB Static 类似） |
| 默认模式 | v6.0+ 默认 dynamic | v5.x 默认 static | 不区分模式 |
| RANGE 裁剪 | 精确，支持复杂表达式 | 仅支持简单范围 | 精确 |
| HASH 裁剪（等值） | 精确单分区 | 可裁剪但可能多出一步 | 精确 |
| HASH 裁剪（范围） | 通过 RPC 合并优化 | 每个分区单独 RPC | UNION ALL 下推 |
| 多分区扫描 | 单 RPC，TiKV 内部并行 | 多 RPC（每分区一次） | UNION ALL 多子查询 |
| 参数化查询 | 支持（参数绑定后裁剪） | 不支持（优化阶段参数未知） | 不支持 |
| EXPLAIN 显示 | `partition:p0,p1,...` | `partition:all` 或单分区 | `partitions` 列 |
| Region 关系 | 分区内数据分散在多个 Region | 同左 | 无 Region 概念 |
| 计划大小 | O(1) | O(n)，n=分区数 | O(n) |

核心差异：
- TiDB Dynamic Pruning 是 MySQL 不具备的能力——将分区裁剪推迟到参数绑定后的执行阶段
- TiDB 的 Region 分布与分区裁剪天然协同：裁剪掉的分区 = 跳过的 Region = 减少的 KV 读取
- MySQL 的分区裁剪始终在优化阶段，且各分区的扫描通过 UNION ALL 逐个子查询完成

## 优化方案

### good.sql

```sql
-- 1. 确认 dynamic pruning 模式
SET SESSION tidb_partition_prune_mode = 'dynamic';

-- 2. RANGE 分区裁剪：只访问对应分区
EXPLAIN SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';
-- access object: partition:p2025  ← 只访问一个分区！

-- 3. 单日精确查询 —— 分区裁剪 + 索引查找
EXPLAIN SELECT * FROM t_order_range
WHERE order_date = '2025-06-15';
-- access object: partition:p2025, IndexRangeScan: range:[2025-06-15,2025-06-15]

-- 4. HASH 分区单值查询 —— 精确裁剪到 p3
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;
-- access object: partition:p3  ← user_id=12345 hash 后落入 p3

-- 5. 查看分区数据分布
SELECT PARTITION_NAME, TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_range';

-- 6. TiDB 专属：查看分区 Region 分布
SHOW TABLE t_order_range REGIONS;
```

### 为什么 Dynamic Pruning 更快

**架构对比**：

```
Static Pruning:
  SQL → 优化器（参数未知）→ 每个分区独立计划
        ├─ Plan_p2024: TableReader → RPC → TiKV Scan p2024
        ├─ Plan_p2025: TableReader → RPC → TiKV Scan p2025
        ├─ Plan_p2026: TableReader → RPC → TiKV Scan p2026
        └─ ...
        → 5 次 RPC，每个分区独立扫描
  
Dynamic Pruning:
  SQL → 优化器 → 统一计划（分区列表作为运行时参数）
        → 1 次 RPC → TiKV → 并行扫描 [p2024, p2025, p2026, ...]
        → 1 次 RPC，TiKV 内部并行处理
```

**三重优势**：

1. **RPC 合并**：Static 模式下 5 个分区 = 5 次 RPC；Dynamic 模式下 1 次 RPC 覆盖所有目标分区，网络开销降低 80%
2. **Plan Cache 兼容**：Prepare/Execute 场景下，Static Pruning 因优化阶段参数未知而无法裁剪（保守全分区扫描）；Dynamic Pruning 在参数绑定后才决定分区，执行计划可缓存
3. **分区数弹性**：100 个分区的表，Static 模式生成 100 个子计划（内存开销大），Dynamic 模式 1 个计划（O(1) 大小）

### EXPLAIN 输出中分区裁剪的识别

Dynamic Pruning 的 `access object` 列显示分区列表：

- `partition:p2025` — 裁剪到单个分区
- `partition:p2024,p2025` — 裁剪到两个分区
- `partition:all` — 未裁剪，所有分区都访问（需要排查）

### TiDB 分区与 Region 分布的协同

```
t_order_range 表的 Region 分布示意:
  p2024 → Region [t_100, t_199]  → TiKV Node 1（Leader）
                                → TiKV Node 2（Follower）
  p2025 → Region [t_200, t_299]  → TiKV Node 2（Leader）
                                → TiKV Node 3（Follower）
  p2026 → Region [t_300, t_399]  → TiKV Node 3（Leader）
                                → TiKV Node 1（Follower）
```

分区裁剪 = Region 跳过：查询 `WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31'` 裁剪到 p2025 → 只访问 Region [t_200, t_299] → TiKV Node 2 处理。其余 4 组 Region 完全跳过。

这与 MySQL 的本质区别在于：TiDB 的"跳过"是在分布式 KV 层面实现的，每个分区是独立的 Region 组。MySQL 即使在分区裁剪后，数据仍在本地 InnoDB 表空间中。

## 深入原理

### Dynamic Pruning 的内部机制

```
查询: SELECT * FROM t_order_range WHERE order_date BETWEEN ? AND ?

Step 1 - 优化阶段 (Prepare/Plan Cache MISS):
  SQL 解析 → AST → 逻辑优化（列裁剪、谓词下推）
  → 物理优化（算子选择、成本估算）
  → 生成执行计划（分区信息保留为参数）
  → 缓存计划（key = SQL_DIGEST）

Step 2 - 执行阶段 (EXECUTE USING @p1, @p2):
  ① 参数绑定: @p1 = '2025-01-01', @p2 = '2025-12-31'
  ② 分区解析: 根据参数值计算匹配的分区列表
     - YEAR('2025-01-01') = 2025 → p2025 (2025 <= year < 2026)
     - YEAR('2025-12-31') = 2025 → p2025
     - 目标分区: [p2025]
  ③ 构建 KV Range: 为每个匹配分区生成对应的 Key Range
     - p2025 的 table_id → [t{partition_id}_r..., t{partition_id}_s...)
  ④ 下发请求: 单次 coprocessor 请求，包含所有 KV Range
  ⑤ TiKV 执行: 并行扫描对应 Region，返回结果
```

### 分区裁剪的判断条件

TiDB 能裁剪分区的条件表达式：

| 条件类型 | RANGE 分区 | HASH 分区 | LIST 分区 |
|---------|-----------|----------|----------|
| `col = const` | 可裁剪 | 可裁剪（单分区） | 可裁剪 |
| `col > const AND col < const` | 可裁剪 | 不能（范围覆盖多哈希值） | 可裁剪 |
| `YEAR(col) = const` | 可裁剪（等价于范围） | 不能 | N/A |
| `col IN (v1, v2)` | 可裁剪 | 可裁剪（可能多分区） | 可裁剪 |
| `col BETWEEN v1 AND v2` | 可裁剪 | 不能 | 可裁剪 |
| `col = @var`（用户变量） | Static: 不能 / Dynamic: 能 | 同左 | 同左 |
| `col = ?`（Prepared） | Static: 不能 / Dynamic: 能 | 同左 | 同左 |

**关键规则**：Dynamic Pruning 的裁剪能力 = Static Pruning + 参数化查询 + 运行时表达式求值。这刚好覆盖了高并发 OLTP 中最常见的 Prepare/Execute 模式。

### Global Index 与分区表

TiDB v7.5+ 支持 Global Index（全局索引），允许在非分区键上创建跨分区的唯一索引：

```sql
-- 传统分区表：唯一索引必须包含分区键
CREATE TABLE t (
    id BIGINT,
    order_date DATE,
    order_no VARCHAR(32),
    PRIMARY KEY (id, order_date),    -- 必须包含分区键
    UNIQUE KEY uk_order_no (order_no, order_date)  -- 必须包含分区键
) PARTITION BY RANGE (YEAR(order_date)) (...);

-- TiDB v7.5+ Global Index：唯一索引不需要包含分区键
CREATE TABLE t (
    id BIGINT PRIMARY KEY,
    order_date DATE,
    order_no VARCHAR(32),
    UNIQUE KEY uk_order_no (order_no)  -- Global Index，不包含分区键
) PARTITION BY RANGE (YEAR(order_date)) (...);
```

Global Index 的查询仍然受益于 Partition Pruning——如果 WHERE 条件中包含分区键，即使走 Global Index，也能进一步减少扫描分区。

### 监控分区裁剪效果

```sql
-- 查看分区裁剪模式
SHOW VARIABLES LIKE 'tidb_partition_prune_mode';

-- 查看分区信息
SELECT TABLE_NAME, PARTITION_NAME, TABLE_ROWS, AVG_ROW_LENGTH, DATA_LENGTH
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 't_order%'
ORDER BY TABLE_NAME, PARTITION_ORDINAL_POSITION;

-- 查看表的 Region 分布（TiDB 专属）
SHOW TABLE t_order_range REGIONS;

-- 在 Grafana 中监控:
-- TiDB → DistSQL → Coprocessor 请求 QPS（应下降）
-- TiKV → Coprocessor → Scan 行数（应下降）
```

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 97-tidb-partition --ver tidb
```

执行后观察：

- `SHOW VARIABLES LIKE 'tidb_partition_prune_mode'` 确认当前模式
- bad.sql 中 EXPLAIN 输出的 `access object` 是否为 `partition:all`
- good.sql 中设置 dynamic 后，同一条 SQL 的 `access object` 变为 `partition:p2025`
- `SELECT ... FROM information_schema.PARTITIONS` 查看各分区行数分布
- `SHOW TABLE t_order_range REGIONS` 查看 TiDB 独有的 Region 分布
- 对比 Static 和 Dynamic 模式下 EXPLAIN 输出的差异

::: warning 重要提示

复现时注意：
1. Dynamic Pruning 是 TiDB v6.0+ 才引入的特性，v5.x 不支持。确认测试环境使用的是 TiDB v6.0 或更高版本
2. `tidb_partition_prune_mode` 是 SESSION 级变量，可以在会话内动态切换以对比效果
3. 如果切换后 EXPLAIN 仍显示 `partition:all`，检查 WHERE 条件是否能让优化器推断分区范围——例如 `YEAR(order_date) = 2025` 等价于范围条件，而 `MONTH(order_date) = 6` 则不能用于分区裁剪
4. HASH 分区表上 `SHOW TABLE REGIONS` 的输出与 RANGE 分区相同，但 Region 对应的 Key 范围由 HASH 算法决定
5. 分区裁剪只减少扫描范围，不会改变扫描方式——如果分区内没有合适的索引，仍然是 TableFullScan（只是在一个分区内全扫）

:::

## 常见问题

**Q: Dynamic Pruning 和 Static Pruning 应该选哪个？**

A: 绝大多数场景选 Dynamic（v6.x+ 默认）。Static Pruning 仅在极少数调试场景下有用——当你想查看每个分区独立的执行计划时。生产环境始终使用 Dynamic Pruning。

**Q: 为什么切换 Dynamic Pruning 后 EXPLAIN 中看不到分区列表了？**

A: Dynamic Pruning 的分区信息在 EXPLAIN 输出中位于 `access object` 列，格式为 `partition:p0,p1,...`。如果显示为 `partition:all`，说明条件无法用于分区裁剪（检查 WHERE 条件是否涉及分区键）。

**Q: HASH 分区什么时候能裁剪，什么时候不能？**

A: HASH 分区的裁剪规则：等值条件（`user_id = 12345`）可精确裁剪到单个分区；`IN` 条件可裁剪到可能的分区；`BETWEEN`、`>`、`<` 等范围条件覆盖多哈希值，无法裁剪（需要扫描所有分区）。这是 HASH 分区的数学限制，与 TiDB 或 MySQL 无关。

**Q: 分区表上 Global Index 和 Partition Pruning 能同时生效吗？**

A: 能。如果查询同时包含分区键条件和索引键条件，TiDB 可以同时利用 Partition Pruning（跳过无关分区）和索引查找（在目标分区内快速定位行）。例如 `SELECT * FROM t WHERE order_no = 'NO123' AND order_date = '2025-06-15'` 会先裁剪到 p2025 分区，再在该分区内通过 Global Index 查找 order_no。

**Q: 分区裁剪与 Coprocessor 下推是什么关系？**

A: 两者是独立的优化维度。分区裁剪决定了"访问哪些分区（哪些 Region）"；Coprocessor 下推决定了"在 TiKV 上执行哪些计算（过滤、聚合等）"。好的查询两个优化同时生效：裁剪减少了 Region 数量，下推减少了 TiDB Server 与 TiKV 之间的数据传输。

**Q: TiDB 多分区扫描时内部是如何并行的？**

A: Dynamic Pruning 下发的是单个 Coprocessor 请求，但该请求包含多个 Key Range（每个分区一个）。TiKV 内部会将这些 Key Range 拆分到不同的 Scanner 线程并行扫描，最后汇总结果返回 TiDB。这是 TiKV 层面的并行，对 TiDB Server 透明。
