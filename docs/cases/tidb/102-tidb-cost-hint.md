# TiDB Cost Model 与优化器 Hint 进阶

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['Hint', '优化器', 'Cost Model', 'agg_push_down', 'limit_push_down', 'hint']" />

## 90%失败
你负责一个用户行为分析平台，表 `t_hint_test` 存储用户的行为记录，其中 `status` 字段表示行为状态：0=失败、1=成功、2=处理中。由于业务特性，90% 的记录都是成功状态（status=1），数据分布严重倾斜。

某天，产品经理需要导出"北京地区成功行为中 score 最高的 20 条记录"：

```sql
SELECT * FROM t_hint_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY score DESC
LIMIT 20;
```

查询执行了 3 秒才返回——对有索引的 20 万行表来说慢得不正常。你查看执行计划后发现，优化器选择了 `idx_status` 索引而非 `idx_city`。问题是：**status=1 占了 90% 的行（18 万行），是一个极低选择性的条件，而 city='Beijing' 只占约 10%（~2 万行）**。优化器高估了 status 索引的选择性，导致先扫描 18 万行再过滤 city。

::: warning 真实场景
在 MySQL 生态中，Hint 通常被视为"最后一招"——大多数 DBA 只使用 `STRAIGHT_JOIN` 和 `FORCE INDEX`，很少触及优化器的深层开关。但 TiDB 的分布式架构引入了一系列 MySQL 中没有的优化决策：聚合是否下推到 TiKV？LIMIT 是否下推以减少网络传输？Join 使用 Hash 还是 Index Loop？这些决策在单机 MySQL 中不存在，但会严重影响 TiDB 的查询性能。TiDB 为此提供了超过 10 种 Hint，配合 `tidb_opt_agg_push_down` 等变量精细控制优化器行为——远比 MySQL 的 Hint 更丰富，与分布式架构紧密相关。

如果你不清楚这些 Hint 和开关的用法，面对"优化器选错计划"的问题时，你可能只能用 `USE INDEX` 硬修正——而不知道可以通过 `SET_VAR` 临时调整优化器策略来诊断根因。
:::

## 问题分析

### bad.sql：优化器默认选择的问题

本案例通过三个场景展示优化器默认行为的局限性：

```sql
-- 场景1: 高选择性 + 低选择性条件组合下优化器选错索引
EXPLAIN SELECT * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' ORDER BY score LIMIT 20;

-- 场景2: 聚合未下推到 TiKV，所有数据在 TiDB Server 层聚合
EXPLAIN SELECT city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;

-- 场景3: 查看当前优化器开关状态
SHOW VARIABLES LIKE 'tidb_opt_agg_push_down';
SHOW VARIABLES LIKE 'tidb_opt_limit_push_down_threshold';
```

### 场景1 解读：为啥选 idx_status 而不是 idx_city

```
IndexLookUp_20
├─IndexRangeScan_17(Build)   | index:idx_status | range:[1,1]
└─TopN_19(Probe)
  └─Selection_18             | eq(city, "Beijing")
    └─TableRowIDScan_19
```

优化器选择的路径是：先通过 `idx_status` 扫描所有 status=1 的行（预估 18000 行，实际 18 万行），然后在 Probe 阶段回表过滤 city='Beijing'，再按 score 排序取 Top 20。

问题出在 **cost model 对倾斜分布的估算偏差**：

1. **status=1 选择性估算不准**：优化器基于直方图估算 status=1 的扫描行数为 ~18000，但实际是 18 万行——偏差 10 倍
2. **city 的高选择性未被充分利用**：city='Beijing' 只有约 2 万行，选择性远优于 status=1，但优化器未优先考虑
3. **ORDER BY + LIMIT 干扰**：TopN 算子需要按 score 排序，优化器在"先过滤再排序"的策略评估上出现偏差

### 场景2 解读：聚合在 root task 还是 cop task

```
HashAgg_9          | task: root      -- 聚合在 TiDB Server 层
└─TableReader_10   | task: root
  └─TableFullScan_8 | task: cop[tikv] -- 扫描在 TiKV 层
```

当聚合在 `root` task 时，20 万行的原始数据从 TiKV 通过网络传输到 TiDB Server 层再聚合。如果开启 `tidb_opt_agg_push_down = ON`（默认），TiDB 会将 `COUNT(*)` 和 `SUM(score)` 下推到 TiKV——每个 TiKV 节点先在本地做部分聚合，只传输聚合后的少量结果到 TiDB Server 做最终合并。

### TiDB Cost Model 核心因子

优化器做决策时评估以下成本因子，Hint 可以针对性地覆盖每个因子：

| 因子 | 系统变量 | 相关 Hint | 影响 |
|------|---------|-----------|------|
| **行数估算** | 统计信息（ANALYZE） | — | `estRows` 是所有决策的基础 |
| **网络开销** | `tidb_opt_agg_push_down` | `SET_VAR` / `AGG_TO_COP` | 决定数据在 TiKV 还是 TiDB 层处理 |
| **CPU 开销** | `tidb_opt_limit_push_down_threshold` | `SET_VAR` / `LIMIT_TO_COP` | LIMIT 下推减少不必要的行处理 |
| **内存开销** | `tidb_mem_quota_query` | `MEMORY_QUOTA` / `HASH_AGG` / `STREAM_AGG` | 聚合算法的内存占用 |
| **I/O 模式** | `tidb_enable_chunk_rpc` | `READ_FROM_STORAGE` | TiKV（行存）vs TiFlash（列存） |
| **Join 算法** | — | `HASH_JOIN` / `INL_JOIN` / `MERGE_JOIN` | Join 算子的 CPU/内存 trade-off |

## 优化方案

### good.sql：用 Hint 精细控制执行计划

针对上述三个问题，TiDB 提供了对应的 Hint 解决方案：

```sql
-- 1. USE_INDEX: 强制走 idx_city（高选择性索引）
EXPLAIN SELECT /*+ USE_INDEX(t_hint_test, idx_city) */ * FROM t_hint_test
WHERE status = 1 AND city = 'Beijing' LIMIT 20;

-- 2. HASH_AGG / STREAM_AGG: 显式指定聚合算法
EXPLAIN SELECT /*+ HASH_AGG() */ city, COUNT(*), SUM(score)
FROM t_hint_test GROUP BY city;

-- 3. SET_VAR: 单条语句临时关闭聚合下推，对比效果
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_agg_push_down=OFF) */ city, COUNT(*)
FROM t_hint_test GROUP BY city;

-- 4. MAX_EXECUTION_TIME: 设置查询超时保护
SELECT /*+ MAX_EXECUTION_TIME(5000) */ COUNT(*) FROM t_hint_test;

-- 5. READ_FROM_STORAGE: 指定存储引擎
EXPLAIN SELECT /*+ READ_FROM_STORAGE(TIKV[t_hint_test]) */ city, COUNT(*)
FROM t_hint_test GROUP BY city;
```

### 纠正场景1：USE_INDEX 强制走 idx_city

```
IndexLookUp_13
├─IndexRangeScan_10(Build)   | index:idx_city | range:["Beijing","Beijing"]
└─Selection_12(Probe)        | eq(status, 1)
  └─TableRowIDScan_11
```

变化：Build 阶段扫描 idx_city（~2 万行），Probe 阶段过滤 status=1。相比之前扫描 idx_status（18 万行），**扫描行数减少到 1/9**。

由于 city='Beijing' 的结果集较小（~2 万行），排序和 LIMIT 20 的开销也大幅下降。

### 纠正场景2：SET_VAR 验证聚合下推效果

```sql
-- 默认：聚合下推（good）
EXPLAIN SELECT city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;
-- HashAgg 的 task: cop[tikv]（下推），网络传输 10 行聚合结果

-- 临时关闭下推（对比）
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_agg_push_down=OFF) */ city, COUNT(*)
FROM t_hint_test GROUP BY city;
-- HashAgg 的 task: root（不下推），网络传输 20 万行原始数据
```

SET_VAR 的强大之处在于：它只影响当前这条 SQL，不会改变会话级或全局级设置。这对诊断"聚合下推是否导致了问题"非常有用。

### bad vs good 量化对比

| 指标 | bad.sql（默认） | good.sql（Hint） | 提升 |
|------|---------------|----------------|------|
| 场景1 使用索引 | `idx_status` | `idx_city` | — |
| 场景1 扫描行数 | ~18 万行（90%） | ~2 万行（10%）| **减少 89%** |
| 场景1 TopN 输入 | 18 万行 | 2 万行 | **减少 89%** |
| 场景2 聚合位置 | cop[tikv]（下推） | cop[tikv] 或 root（可控）| 可验证 |
| 场景2 网络传输 | 10 行 | 20 万行（对比验证用）| — |
| 查询超时保护 | 无 | 5s 自动中断 | 安全兜底 |

### Hint 分层使用策略

并非所有场景都需要用 Hint。推荐分层策略如下：

| 层级 | 手段 | 典型场景 |
|------|------|---------|
| **第 1 层：ANALYZE** | 更新统计信息 | 统计过期导致估算偏差 |
| **第 2 层：SET_VAR** | 单条 SQL 调整优化器开关 | 诊断聚合/limit 下推问题 |
| **第 3 层：USE_INDEX / IGNORE_INDEX** | 指定/排除索引 | 明确知道哪个索引更好 |
| **第 4 层：Join / Agg Hint** | 指定算法（HASH_JOIN 等）| 优化器算法选择不当 |
| **第 5 层：SQL 重写** | 改写 SQL 逻辑 | Hint 无法解决的根因问题 |

## 避坑指南

::: warning TiDB Hint 使用注意事项

1. **Hint 不是银弹**。使用 Hint 之前，务必确认统计信息是准确的（`SHOW STATS_HEALTHY`）。很多"选错索引"的问题实际上是因为统计过期，更新统计后优化器自己就能选对。

2. **USE_INDEX 在 TiDB 中等同于 FORCE_INDEX**。与 MySQL 不同，TiDB 中 `USE_INDEX` 和 `FORCE_INDEX` 效果相同——都会强制使用指定索引，排除其他候选。TiDB 没有 MySQL 那种"建议但不强制"的 USE INDEX 语义。

3. **HASH_AGG vs STREAM_AGG 不可混用**。`STREAM_AGG` 要求输入数据按 group key 有序（执行计划中会出现 `keep order:true`）。如果数据本身无序，优化器会额外插入一个 Sort 算子，反而可能更慢。

4. **STRAIGHT_JOIN 有全局影响**。与 MySQL 一样，`STRAIGHT_JOIN` 强制按 FROM 子句的表顺序进行 Join。在 TiDB 中还可以配合 `LEADING` Hint 更灵活地指定 Join 顺序。

5. **SET_VAR 是最被低估的 Hint**。它允许对单条 SQL 临时调整任意系统变量，而不会影响其他查询。诊断优化器问题时，`SET_VAR(tidb_opt_agg_push_down=OFF)` 可以快速验证"聚合不下推是否是问题根因"。

6. **READ_FROM_STORAGE 需要副本支持**。指定 `TIFLASH` 前需要确认 TiFlash 副本已同步完毕（`SELECT * FROM information_schema.tiflash_replica`），否则查询会失败。

7. **MAX_EXECUTION_TIME 不适用于所有阶段**。超时检测仅在特定检查点触发，如果查询卡在 TiKV 层的扫描（如大范围扫描），可能在较长时间后才能响应超时中断。

8. **MEMORY_QUOTA 和 tidb_mem_quota_query 的关系**。`MEMORY_QUOTA` Hint 的优先级高于系统变量 `tidb_mem_quota_query`，但只影响当前语句。

9. **版本差异**。不同 TiDB 版本支持的 Hint 略有差异，请参考 [TiDB 官方文档 - Optimizer Hints](https://docs.pingcap.com/tidb/stable/optimizer-hints) 获取最新版本信息。

:::

## 本地复现

```bash
./scripts/run-case.sh 102-tidb-cost-hint --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```
:::
