# TiDB Dashboard 诊断实战

<CaseMeta difficulty="⭐⭐" category="TiDB 诊断工具" versions="TiDB" :tags="['Dashboard', 'TopSQL', 'Key Visualizer', '慢查询', '诊断', 'Statement Analysis']" />

## 场景痛点

凌晨 2:15，你被 PagerDuty 告警吵醒。Grafana 显示 TiDB 集群的 CPU 使用率从平时的 35% 飙升至 92%，P99 延迟从 50ms 飙升到 5.2 秒。你 SSH 登录到跳板机，打开 TiDB Dashboard（`http://127.0.0.1:2379/dashboard`）。

Dashboard 首页的 **Overview** 面板已经勾勒出问题轮廓：

- **QPS**：正常水平（约 8,000/s），没有突发流量
- **P99 延迟**：从 50ms 拉升至 5.2s，且集中在凌晨 02:00-03:00
- **TiDB CPU**：3 个 TiDB Server 节点均在 90%+，TiKV 节点 CPU 正常（说明瓶颈在 SQL 层而非存储层）

你没有先去翻慢查询日志，也没有盲猜索引问题。你直接点击了 Dashboard 最核心的诊断模块：**TopSQL**。

选择时间窗口 `02:00 - 03:00`，TopSQL 面板的柱状图立刻揭示了真相——**一条 SQL 模板独占了集群 87% 的 CPU 时间**，总 CPU 耗时高达 6,858,069ms（约 1.9 小时 CPU 时间）。点击该 Digest，直接跳转到 Statement Analysis 查看详情：这是一条 `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` 查询，执行了 15,230 次，平均每次耗时 2.3 秒。

从告警响起到定位罪魁祸首 SQL，全程不到 3 分钟——这就是 TiDB Dashboard 的设计目标：**让诊断不再依赖 DBA 手工拼 SQL**。

::: warning 真实场景

在 MySQL 生态中，类似问题的排查路径通常是：`SHOW FULL PROCESSLIST` → 找到慢查询 → `EXPLAIN` → `SHOW PROFILE` → 查 Performance Schema 的 `events_statements_summary_by_digest` → 手工计算 CPU 占比。每一步都需要手写 SQL，且缺乏时间维度的可视化对比。TiDB Dashboard 将这些信息聚合在同一界面中，以图形化方式呈现，极大降低了诊断门槛。

:::

## 问题分析

### Dashboard 诊断架构

TiDB Dashboard 的数据并非凭空产生——它读取的是 TiDB 内置的系统表，本质上是对这些数据源的可视化聚合：

```
┌─────────────────────────────────────────────────────┐
│                  TiDB Dashboard                      │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐   │
│  │ TopSQL   │ │  Key     │ │ Statement         │   │
│  │          │ │Visualizer│ │ Analysis          │   │
│  └────┬─────┘ └────┬─────┘ └────────┬──────────┘   │
│       │             │               │               │
│  ┌────┴─────┐ ┌─────┴──────┐ ┌──────┴────────────┐  │
│  │ Slow     │ │ Traffic   │ │ Compare           │  │
│  │ Query    │ │ Visualizer│ │ (时间对比)         │  │
│  └──────────┘ └────────────┘ └───────────────────┘  │
└──────────────────────┬──────────────────────────────┘
                       │
       ┌───────────────┼───────────────┐
       │               │               │
┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────────────┐
│ cluster_    │ │ cluster_    │ │ PD Region API       │
│ statements_ │ │ slow_query  │ │ (Key Visualizer)    │
│ summary     │ │             │ │                     │
└─────────────┘ └─────────────┘ └─────────────────────┘
```

每个 Dashboard 模块都有其底层数据源：

| Dashboard 模块 | 底层数据源 | 刷新频率 |
|---------------|-----------|---------|
| TopSQL | `information_schema.cluster_statements_summary` + CPU 采样 | 实时（秒级） |
| Slow Query | `information_schema.cluster_slow_query` | 实时 |
| Statement Analysis | `information_schema.cluster_statements_summary` | 聚合统计 |
| Key Visualizer | PD API（Region 读写流量监控） | 实时 |
| Overview | 以上多源聚合 | ~10s |
| Compare | `cluster_statements_summary_history` 快照对比 | 按需 |

### bad.sql：从系统表查询诊断数据

即使无法访问 Dashboard UI（例如仅 CLI 环境），你也可以直接查询底层系统表获取相同的诊断数据：

```sql
-- 1. 慢查询定位（对应 Dashboard Slow Query 面板）
SELECT * FROM information_schema.cluster_slow_query ORDER BY time DESC LIMIT 5;

-- 2. 当前活跃查询（对应 Overview 中的 Active Connections）
SELECT * FROM information_schema.cluster_processlist
WHERE command != 'Sleep' AND time > 1;

-- 3. TopSQL 数据（对应 Dashboard TopSQL 面板）
SELECT DIGEST_TEXT, SUM_EXEC_COUNT, AVG_LATENCY, MAX_LATENCY
FROM information_schema.cluster_statements_summary
ORDER BY AVG_LATENCY DESC LIMIT 5;

-- 4. CPU 消耗排名（TopSQL 按 CPU 排序的依据）
SELECT DIGEST_TEXT, AVG_CPU_TIME_MS, SUM_CPU_TIME_MS
FROM information_schema.cluster_statements_summary
ORDER BY SUM_CPU_TIME_MS DESC LIMIT 5;
```

返回结果示例（参考 `expected/explain-bad.md` 详细输出）：

| DIGEST_TEXT | EXEC_COUNT | AVG_LATENCY | SUM_CPU_TIME_MS |
|-------------|------------|-------------|-----------------|
| `SELECT * FROM t_diag WHERE city = ? AND score > ? ...` | 15,230 | 2,340ms | 6,858,069ms |
| `SELECT * FROM t_diag WHERE user_id = ? ...` | 8,450 | 450ms | 723,320ms |

第一条 SQL **独占集群 87% 的 CPU 时间**，是根因无疑。

### 为什么这条 SQL 如此昂贵

从 `cluster_processlist` 可以看到，这些查询全部处于 `Sending data` 状态且持续 40 秒以上。`Sending data` 在 TiDB 中表示 TiKV 正在向 TiDB Server 传输数据——说明 **回表开销巨大**。

表 `t_diag` 在 `city` 列有索引 `idx_city`，查询 `WHERE city = 'Beijing' AND score > 80` 可以使用该索引定位行。但 `SELECT *` 需要 `name`、`age`、`user_id`、`created_at` 等非索引列，这意味着：
1. 通过 `idx_city` 索引找到所有 `city = 'Beijing'` 的行（约 30,000 行，因为种子数据中 Beijing 占比约 25%）
2. 对这 30,000 行逐一**回表**读取完整行数据
3. 在 TiDB Server 层过滤 `score > 80` 条件
4. 按 `created_at` 排序

即使仅 15,230 次执行，每次扫描 30,000 行的回表开销乘以执行次数就构成了巨大的 CPU 消耗。

::: tip 核心认知

TiDB Dashboard 的价值不在于它能看"无法获取的数据"——所有 Dashboard 面板的数据你都可以通过 `information_schema` 的 SQL 查询获得。它的价值在于**聚合、可视化、时间轴对比**这三件事。一个 Digest 的 CPU 占比柱状图比 `SELECT SUM_CPU_TIME_MS FROM ...` 的数字直观得多；Key Visualizer 的热力图比 `SHOW TABLE REGIONS` 的输出更容易发现热点；Compare 面板让"今天和昨天的同一时段有何不同"这个关键问题变得一键可答。

:::

## 优化方案

### good.sql：Dashboard 诊断链路及数据源查询

当你已经通过 Dashboard 定位到问题 SQL 后，下一步是使用 Dashboard 的更多功能进行深入分析：

```sql
-- 1. 确认 TopSQL 已启用（Dashboard TopSQL 的前提）
SHOW VARIABLES LIKE 'tidb_enable_top_sql';

-- 2. Statement Analysis：查看同一 Digest 的执行统计（Dashboard 点进去就是这张表的数据）
SELECT DIGEST_TEXT, PLAN_DIGEST, EXEC_COUNT, AVG_AFFECTED_ROWS
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%' ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 3. 查看是否有多个执行计划（Plan Digest 变化说明计划不稳定）
SELECT DIGEST_TEXT, PLAN_DIGEST, EXEC_COUNT, AVG_LATENCY
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%'
ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 4. Compare：对比历史时间段
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_LATENCY
FROM information_schema.cluster_statements_summary_history
WHERE DIGEST_TEXT LIKE '%t_diag%'
ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 5. 集群整体统计
SELECT
    COUNT(DISTINCT DIGEST_TEXT) AS unique_sql_templates,
    SUM(EXEC_COUNT) AS total_executions,
    ROUND(AVG(AVG_LATENCY), 2) AS overall_avg_latency_ms
FROM information_schema.cluster_statements_summary;
```

### 完整的 Dashboard 诊断路径

对于凌晨 CPU 飙升的场景，推荐的诊断路径如下：

| 步骤 | Dashboard 模块 | 操作内容 | 关键发现 |
|------|---------------|---------|---------|
| 1 | **Overview** | 查看 QPS / P99 延迟 / 各节点 CPU | P99 延迟 5.2s，TiDB CPU 90%+，TiKV 正常 |
| 2 | **TopSQL** | 选择时间窗口 `02:00-03:00`，按 CPU 排序 | 一条 SQL 占 87% 集群 CPU |
| 3 | **Slow Query** | 过滤相同时间范围，按 Digest 聚合 | 该 Digest 产生 5 条慢查询，最长 8.2s |
| 4 | **Statement Analysis** | 点击 Digest 查看详细统计 | 平均影响 3,200 行，`SELECT *` 回表巨大 |
| 5 | **Key Visualizer** | 查看 `t_diag` 表 Region 流量 | `idx_city` Region 读取流量异常集中 |
| 6 | **Compare** | 对比前一天 `02:00-03:00` | 昨天同 SQL 平均延迟仅 80ms——凌晨有变更 |
| 7 | **Profiling** | `EXPLAIN ANALYZE` 确认执行计划 | `IndexLookUp` + 大量回表 |

### 快速止血措施

定位到根因后，根据实际情况选择止血方案：

1. **紧急加索引**：如果 `score` 过滤选择性好，添加 `(city, score)` 联合索引避免回表
2. **改写为覆盖索引查询**：将 `SELECT *` 改为 `SELECT id, city, score, created_at`，配合 `(city, score, created_at)` 覆盖索引
3. **限流**：通过 `tidb_expensive_query_time_threshold` 或应用层对该 SQL 模板限流
4. **SQL Hint**：如果优化器选错了索引，使用 `USE INDEX` 临时纠正
5. **回滚变更**：如果 Compare 面板确认是近期代码部署引入的 SQL，优先回滚

## 深入原理

### Dashboard vs MySQL Performance Schema 诊断对比

TiDB Dashboard 的设计理念与 MySQL Performance Schema（P_S）的诊断方式有本质差异。以下从多个维度对比：

| 诊断需求 | TiDB Dashboard | MySQL Performance Schema |
|---------|---------------|-------------------------|
| **找 CPU 最高的 SQL** | TopSQL 面板，点击时间窗口即可，柱状图展示 CPU 占比 | 查询 `sys.x$statement_analysis` 或 `performance_schema.events_statements_summary_by_digest`，手工计算 CPU 占比，无时间轴 |
| **找慢查询** | Slow Query 面板，支持 Digest 聚合、时间范围过滤、实例过滤 | 查询 `mysql.slow_log` 或 `sys.statements_with_runtimes_in_95th_percentile`，需手写 SQL |
| **定位热点数据** | Key Visualizer 热力图，按 Region 展示读写字节数/行数，拖动时间轴可回放 | 无对应能力（MySQL 单机架构无 Region 概念），只能通过 `innodb_io_pattern` 间接推断 |
| **SQL 趋势对比** | Compare 面板，两个时间段并排展示 Digest 级别的执行次数、延迟、CPU 变化 | 需要对 `events_statements_summary_by_digest` 做两次快照然后手工 diff |
| **活跃连接诊断** | Overview 集成展示 + Process List | `SHOW PROCESSLIST` 或 `sys.session`，缺少聚合视图 |
| **SQL 模板分析** | Statement Analysis，一键聚合同一 Digest 的所有执行统计 | `sys.statement_analysis` 功能类似，但需手动查询且无图表 |
| **执行计划诊断** | SQL 详情页内置 EXPLAIN 结果 + Coprocessor 执行时间分解 | 需单独执行 `EXPLAIN FORMAT=JSON`，然后分析 JSON 输出 |
| **使用门槛** | 浏览器打开 Dashboard，点选操作 | 需熟练掌握 sys schema、P_S 表结构、SQL 编写以及各指标含义 |
| **实时性** | TopSQL 实时采集（秒级刷新），Key Visualizer 热力图实时更新 | P_S 表多为累积统计，实时性取决于 `performance_schema` 的采集配置 |
| **历史回溯** | Compare 面板 + `cluster_statements_summary_history` 表 | P_S 默认不持久化历史数据，需要外部采集工具（如 PMM） |
| **架构差异** | 分布式架构：Key Visualizer 可看到每个 TiKV 节点的 Region 负载分布 | 单机架构：无分布式热点概念，诊断集中在单实例内部资源争用 |

**核心差异总结**：

- TiDB Dashboard 面向**分布式 SQL 诊断**，Key Visualizer 是其独有的杀手级功能——在分布式存储中，热点 Region 是比慢 SQL 更隐蔽的性能杀手
- MySQL Performance Schema 面向**单机实例诊断**，诊断粒度更细（等待事件、锁、文件 I/O），但缺乏集群维度的聚合视图
- Dashboard 侧重于**可视化 + 时间轴 + 一键诊断**，降低诊断门槛；P_S 侧重于**可编程性 + 细粒度**，适合自动化诊断脚本

### TopSQL 的实现原理

TopSQL 是 TiDB Dashboard 最具特色的功能。它的工作原理：

1. TiDB Server 以固定频率（默认 1 秒）对所有正在执行的 SQL 做 CPU 采样
2. 采样数据按 SQL Digest 聚合：统计每个 Digest 在采样周期内被"捕捉"到的次数
3. 捕捉次数占比近似等于该 SQL 消耗的 CPU 时间占比
4. 数据聚合后存入 `information_schema.cluster_statements_summary`，Dashboard 读取并可视化

```
TiDB Server 进程
  │
  ├─ 1s CPU 采样 ──► SQL Digest A (正在执行) → 计数器+1
  │                  SQL Digest B (正在执行) → 计数器+1
  │                  SQL Digest A (正在执行) → 计数器+1
  │                  ...
  │
  └─ 聚合 ──► cluster_statements_summary.AVG_CPU_TIME_MS
              cluster_statements_summary.SUM_CPU_TIME_MS
```

这与 Linux `perf top` 的原理类似——通过采样而非精确计时来估算 CPU 占比。在足够多的采样点下（例如 1 小时 = 3600 次采样），统计结果高度准确。

### Key Visualizer 与热点诊断

Key Visualizer 从 PD（Placement Driver）获取每个 Region 的读写流量统计，以热力图形式呈现：

- **横轴**：时间
- **纵轴**：Key Range（按表/索引的 key 区间排序）
- **颜色深度**：读写流量大小（字节数或行数）

热力图中如果某一行（对应某一段 Key Range）颜色特别深，说明该 Region 存在读写热点。热点 Region 会导致：
- 该 Region 所在的 TiKV 节点负载远高于其他节点
- PD 调度器可能触发 Region 分裂和迁移
- 严重时导致请求排队和超时

在我们的案例中，`idx_city` 索引中 `Beijing` 对应的 Key Range 显示为深红色条带——大量查询集中访问 `city = 'Beijing'` 的数据，形成读热点。

### 其他 Dashboard 模块简介

| 模块 | 功能 | 使用场景 |
|------|------|---------|
| **Traffic Visualizer** | 展示 TiDB 节点之间的请求流转（类似分布式 tracing） | 分析跨节点查询的路由路径，定位 TiFlash MPP 查询是否走对节点 |
| **SQL Statements** | 列出所有 SQL 模板及其执行统计 | 应用上线后检查新增了哪些 SQL，是否有非预期的高消耗查询 |
| **Cluster Info** | 展示所有 TiDB/TiKV/PD/TiFlash 节点的状态和配置 | 日常运维巡检，确认节点分布和标签配置 |
| **Log Search** | 聚合搜索所有节点的日志 | 通过关键字搜索错误日志、panic 日志等 |
| **Profiling** | 集成火焰图，对 TiDB/TiKV/PD 做 CPU Profiling | 深度性能分析，定位代码级别的 CPU 热点函数 |

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 98-tidb-dashboard --ver tidb
```

执行后观察：

- `information_schema.cluster_statements_summary` 中各 SQL 模板的执行统计（执行次数、延迟、CPU 时间）
- `information_schema.cluster_slow_query` 中的慢查询记录
- `information_schema.cluster_processlist` 中的活跃连接状态
- 对比 bad.sql 中"问题发现"和 good.sql 中"诊断链路"的思路差异

::: tip 如何使用 Dashboard 进行日常巡检

1. **每天打开 Overview**：扫一眼 QPS、延迟、各节点 CPU/内存，30 秒确认集群健康
2. **每周看一次 TopSQL**：按 CPU 时间排序，看是否有新的高消耗 SQL 出现
3. **部署后立即 Compare**：代码发布后对比发布前后 1 小时的 SQL 执行变化
4. **告警后第一步打开 TopSQL**：选择告警时间窗口，按 CPU 排序，通常 30 秒内定位根因 SQL
5. **定期检查 Key Visualizer**：确认是否有持续的热点 Region，避免单节点过载

Dashboard 不是用来"出了问题才看"的工具——它是集群的体检报告。养成定期查看的习惯，很多问题可以在恶化前被提前发现。

:::

## 常见问题

**Q: TopSQL 面板显示"No Data"，怎么办？**

A: 检查两个配置：(1) `SHOW VARIABLES LIKE 'tidb_enable_top_sql'` 确保为 `ON`（TiDB v6.0+ 默认开启）；(2) TiDB Server 启动时需配置 `--top-sql-address` 参数指向一个用于存储 TopSQL 数据的地址。如果使用 TiUP 部署，默认已配置。

**Q: Dashboard 的 Slow Query 和直接查 `cluster_slow_query` 有什么区别？**

A: 数据来源完全相同——都来自 `information_schema.cluster_slow_query`。Dashboard 的优势在于：(1) 自动按 Digest 聚合，相同模板的慢查询归为一组；(2) 可视化的时间分布图，可以直观看到慢查询是突发还是持续；(3) 一键跳转到 Statement Analysis 查看该 Digest 的详细统计。

**Q: Key Visualizer 中如何区分读热点和写热点？**

A: Key Visualizer 面板顶部有"Read Bytes"、"Write Bytes"、"Read Keys"、"Write Keys"四个切换选项。选择不同指标可以分别查看读/写维度的流量分布。读热点通常是大量查询集中访问某段数据；写热点通常由自增主键或单调递增索引引起。

**Q: Dashboard 会影响 TiDB 集群性能吗？**

A: Dashboard 本身是一个轻量级的 HTTP 服务，嵌入在 PD 进程中，读取的是 TiDB 已经采集的系统表数据，不会对 TiDB 产生额外的查询负载。唯一需要注意：TopSQL 的 CPU 采样有微小开销（通常 <1%），可以通过 `tidb_enable_top_sql = OFF` 关闭。

**Q: 有没有办法通过 API 自动化获取 Dashboard 的数据？**

A: Dashboard 提供了完整的 HTTP API（与 UI 相同的数据接口）。例如获取 TopSQL 数据：`curl http://127.0.0.1:2379/dashboard/api/topsql/v1/summary`。你可以将这些 API 集成到自动化监控脚本中，也可以直接查询 `information_schema` 下的系统表获取相同数据——两者等价。

**Q: Dashboard 对比 MySQL Performance Schema，哪个更适合日常运维？**

A: 这不是二选一的问题——它们面向不同的诊断场景。TiDB Dashboard 擅长分布式层面的快速定位（哪个 Digest 消耗最多 CPU、哪个 Region 有热点）；MySQL Performance Schema 擅长单机细粒度分析（等待事件、锁竞争、文件 I/O）。实际运维中，Dashboard 用于"发现问题是什么"，P_S / 系统表查询则用于"理解问题为什么发生"——两者是互补关系。
