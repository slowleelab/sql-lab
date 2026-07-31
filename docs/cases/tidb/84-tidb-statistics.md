# TiDB 统计信息管理和 ANALYZE

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['统计信息', 'ANALYZE', '健康度', '直方图']" />

## 场景痛点

你负责维护公司的 TiDB 集群。某个周五的晚上，业务团队在低峰期执行了一次批量数据导入（导入了 5 万行新订单数据）。第二天早上你被告警电话吵醒——多条核心查询 SQL 的延迟从原来的 **10ms 飙升到 2s**。

你紧急登录数据库，对那条慢查询执行了 `EXPLAIN`：

```
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| id                            | estRows  | task      | access object             | operator info                    |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
| IndexLookUp_7                 | 18000.00 | root      |                           | stats:pseudo                     |
| ├─IndexRangeScan_5(Build)     | 18000.00 | cop[tikv] | table:t_stats, index:idx_status | range:[1,1], keep order:false |
| └─TableRowIDScan_6(Probe)     | 18000.00 | cop[tikv] | table:t_stats             | keep order:false                 |
+-------------------------------+----------+-----------+---------------------------+----------------------------------+
```

你注意到 `operator info` 那里有一个刺眼的标签：**`stats:pseudo`**。再一看 `SHOW STATS_HEALTHY`，健康度掉到了 **60**。你突然意识到：昨晚的批量导入让统计信息过期了，优化器正在用伪统计（pseudo stats）估算行数——而这些估算与实际偏差可达 **10 到 100 倍**。

::: warning 真实场景
在 TiDB 生产环境中，`stats:pseudo` 是导致查询突然变慢的最常见原因之一。它通常发生在：大批量数据导入后、新建表首次查询前、或统计数据长期未更新时。优化器在无真实统计的情况下，只能用固定规则估算行数，导致选错索引甚至全表扫描。
:::

## 问题分析

### 核心认知：TiDB 如何依赖统计信息

TiDB 是一个基于**成本优化器（Cost-Based Optimizer, CBO）**的分布式数据库。CBO 依赖统计信息来估算每个算子的行数（`estRows`），并选择代价最低的执行计划。TiDB 的统计信息包含三层结构：

| 层级 | 统计类型 | 存储位置 | 用途 |
|------|---------|---------|------|
| 表级 | 总行数 (`Row_count`) | `mysql.stats_meta` | 全表扫描代价估算 |
| 列级 | 直方图 (Histogram) | `mysql.stats_histograms` + `mysql.stats_buckets` | 等值/范围查询选择性估算 |
| 列级 | Count-Min Sketch | `mysql.stats_histograms` | 等值查询的基数估算 |

当 `stats:pseudo` 出现时，这三层统计**全部无效**，优化器退化为用固定比例（如每列估算 `Row_count / 5`）来估算结果行数——这就是 `estRows` 严重失准的根本原因。

### bad.sql：统计信息过期导致执行计划变差

```sql
-- 1. 查看当前统计信息状态
SHOW STATS_HEALTHY WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
SHOW STATS_META WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 2. 模拟"先查后改"：先执行查询建立基线
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';

-- 3. 插入 50000 行新数据（状态全为 0，不更新统计信息）
-- 使用笛卡尔积生成 50000 行：t1(200行) x t2(250行) = 50000
-- 完整可执行 SQL 见 sql/cases/84-tidb-statistics/bad.sql

-- 4. 统计过期后再次 EXPLAIN——优化器仍用旧统计估算
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';
```

#### 关键问题：`stats:pseudo` 的危害

在 EXPLAIN 输出中，`operator info` 列出现 `stats:pseudo` 时，意味着：

1. **行数估算失准**：`estRows` 与实际行数偏差可达 10-100 倍
2. **可能选错索引**：优化器基于错误的估算选择了代价"看起来低"的执行计划
3. **触发全表扫描**：当优化器低估行数时，可能认为全表扫描比索引回表更"便宜"

#### 数据分布与统计的关系

本案例的种子数据中，`status` 列分布极度不均：

| status | 初始行数 | 占比 | 插入 5 万行后 |
|--------|---------|------|-------------|
| 1 | 180,000 | 90% | 180,000 (72%) |
| 0 |  20,000 | 10% |  70,000 (28%) |

批量导入后，`status=0` 的比例从 10% 涨到了 28%，但统计信息不知道这个变化——优化器仍然认为 `status=0` 只有 2 万行，严重低估了查询 `WHERE status=0` 的代价。

### TiDB 统计健康度机制

TiDB 通过 `mysql.stats_meta` 表中的 `modify_count` 追踪统计信息的"过时程度"：

```
健康度 = (1 - modify_count / count) * 100
```

每次表的行被 INSERT/UPDATE/DELETE，`modify_count` 递增。当健康度低于 `tidb_auto_analyze_ratio`（默认 0.5，即 50%）时，TiDB 自动触发后台 `ANALYZE`。

但在以下场景中，自动 ANALYZE 可能来不及执行：

- **大批量写入后立即查询**：自动 ANALYZE 有触发延迟
- **写入发生在自动 ANALYZE 的时间窗口之外**：由 `tidb_auto_analyze_start_time` / `tidb_auto_analyze_end_time` 控制
- **健康度仍在阈值以上但分布已变化**：`modify_count` 反映的是修改量，但无法反映**数据分布偏移**

## 优化方案

### good.sql：主动更新统计信息

```sql
-- 1. 手动 ANALYZE 更新统计
ANALYZE TABLE t_stats;

-- 2. 查看更新后的统计健康度
SHOW STATS_HEALTHY WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 3. 再次 EXPLAIN——统计恢复准确后，优化器选择正确索引
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';

-- 4. 查看列的直方图信息
SHOW STATS_HISTOGRAMS WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 5. 查看统计元数据
SHOW STATS_META WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
```

### ANALYZE 的三种执行方式

| 命令 | 粒度 | 适用场景 |
|------|------|---------|
| `ANALYZE TABLE t_stats` | 整表所有列 | 通用，默认推荐 |
| `ANALYZE TABLE t_stats COLUMNS status, city` | 指定列 | 只关心特定列的统计 |
| `ANALYZE TABLE t_stats INDEX idx_status` | 指定索引 | 只更新索引列的统计 |

### ANALYZE 的执行策略参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `tidb_analyze_version` | 2 | 统计信息收集版本（v1 采样 / v2 全量+TopN） |
| `tidb_auto_analyze_ratio` | 0.5 | 自动 ANALYZE 的触发阈值（健康度 < 50%） |
| `tidb_auto_analyze_start_time` | "00:00 +0000" | 自动 ANALYZE 允许开始的时间 |
| `tidb_auto_analyze_end_time` | "23:59 +0000" | 自动 ANALYZE 允许结束的时间 |
| `tidb_enable_fast_analyze` | OFF | 实验性快速 ANALYZE（采样率更低） |

::: tip 推荐配置
建议将 `tidb_auto_analyze_ratio` 调低到 **0.2 或 0.3**（即健康度 < 20% 或 30% 才自动触发），并在批量写入后**手动执行** `ANALYZE TABLE`，这样更可控。
:::

### bad vs good 量化对比

| 指标 | bad.sql（stale stats） | good.sql（ANALYZE 后） |
|------|----------------------|---------------------|
| 统计状态 | `stats:pseudo` | 真实统计 |
| 健康度 | < 100（取决于写入量） | **100** |
| `Modify_count` | > 0 | 0 |
| `estRows` 准确性 | 偏差 10-100x | **与实际接近** |
| 执行计划可靠性 | 不可预测 | 稳定可预测 |

### 监控脚本：检查集群中所有 stale stats 的表

```sql
-- 查看所有健康度 < 80 的表
SELECT
    db_name,
    table_name,
    healthy,
    state
FROM
    mysql.stats_healthy
WHERE
    healthy < 80
ORDER BY
    healthy ASC;
```

## 避坑指南

::: warning TiDB 统计信息常见误区

1. **`stats:pseudo` 是最危险的红灯信号**。一旦在 EXPLAIN 输出中看到它，说明优化器在"盲猜"行数。应立刻执行 `ANALYZE TABLE`。

2. **批量写入后务必 ANALYZE**。无论是 INSERT、LOAD DATA 还是 BR 恢复，大数据量写入后统计信息必然过期。建议在写入脚本末尾加上 `ANALYZE TABLE`。

3. **不要过度依赖自动 ANALYZE**。`tidb_auto_analyze_ratio` 的默认阈值 0.5 可能不够敏感，当健康度降到 50% 时才触发，此时估算偏差可能已经很大。同时自动 ANALYZE 受时间窗口限制，可能根本不触发。

4. **`SHOW STATS_HEALTHY` 不等于完全准确**。健康度基于 `modify_count / count` 的比值，只反映"有多少比例的修改未统计"，但**无法反映数据分布的偏移**。即使健康度为 100，如果数据从未 ANALYZE 过（`stats:pseudo`），健康度也可能不存在。

5. **区分"无统计"和"过期统计"**。新建表首次查询前执行 `EXPLAIN` 会看到 `stats:pseudo`——因为从未 ANALYZE。导入数据后也会出现——因为统计过期。两者的原因不同，但现象和解决方法（`ANALYZE TABLE`）相同。

6. **ANALYZE 本身有代价**。`ANALYZE TABLE` 会全表扫描并采样，在超大表上可能持续数分钟。需要通过 `tidb_auto_analyze_start_time` / `tidb_auto_analyze_end_time` 控制时间窗口，避免在高峰期执行。

7. **统计信息持久化在 TiKV 中**。与 MySQL 的 `mysql.innodb_table_stats` 不同，TiDB 的统计信息存储在 `mysql.stats_*` 系统表中，但这些表数据最终存储在 TiKV。统计分析 (ANALYZE) 的计算在 TiDB Server 层完成，结果写入 TiKV。

8. **分布式 ANALYZE vs 单点 ANALYZE**。TiDB v5.0+ 支持 `tidb_analyze_version = 2`，采样过程可以并行利用多个 TiKV 节点，大幅加快大表的 ANALYZE 速度。
:::

### TiDB vs MySQL 统计信息对比

对于有 MySQL 经验的 DBA，理解 TiDB 与 MySQL 在统计信息管理上的差异至关重要：

| 维度 | MySQL | TiDB |
|------|-------|------|
| 统计存储 | `mysql.innodb_table_stats` / `mysql.innodb_index_stats` | `mysql.stats_meta` / `mysql.stats_histograms` / `mysql.stats_buckets` |
| 统计层级 | 表级 + 索引级（基数） | 表级 + 列级直方图 + CM Sketch |
| 自动更新 | InnoDB 后台自动更新（持久化统计） | 基于健康度阈值自动触发 `ANALYZE` |
| 健康度概念 | 无 | `SHOW STATS_HEALTHY` 显式展示 |
| 伪统计 | 无（始终有统计，哪怕不准确） | `stats:pseudo` 表示完全无统计 |
| 直方图 | 8.0+ 支持 `ANALYZE TABLE ... UPDATE HISTOGRAM` | 内置支持，`ANALYZE` 自动收集 |
| 采样方式 | 随机页采样（`innodb_stats_persistent_sample_pages`） | 蓄水池采样（Reservoir Sampling） |
| ANALYZE 粒度 | 整表 | 支持 `COLUMNS` / `INDEX` 粒度 |
| 统计过期判断 | `innodb_stats_auto_recalc` + 修改行数阈值 | `modify_count / count` 比值（健康度） |
| 统计锁定 | `ANALYZE TABLE ... PERSISTENT FOR` 暂无 | 不支持统计锁定 |

**核心差异**：MySQL InnoDB 引擎会自动更新持久化统计信息（后台线程），而 TiDB 需要 DBA **主动管理**统计信息的更新时机。在 TiDB 中，`ANALYZE TABLE` 不是一个可选的调优操作——它是**保证执行计划正确的必要步骤**。

## 本地复现

```bash
./scripts/run-case.sh 84-tidb-statistics --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```

执行后观察 `SHOW STATS_HEALTHY` 在批量 INSERT 前后的变化，以及 EXPLAIN 输出中 `stats:pseudo` 的消失。
:::
