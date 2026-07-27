# Dashboard 诊断参考结果 - good.sql（诊断链路及最佳实践）

## TiDB v7.5.1（20 万行）

---

### 1. TopSQL 特性状态

```sql
SHOW VARIABLES LIKE 'tidb_enable_top_sql';
```

```
+---------------------+-------+
| Variable_name       | Value |
+---------------------+-------+
| tidb_enable_top_sql | ON    |
+---------------------+-------+
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `tidb_enable_top_sql` | `ON`（TiDB v6.0+） | TopSQL 实时采集各 SQL 的 CPU 消耗，Dashboard TopSQL 面板的数据来源 |

---

### 2. Statement Analysis 数据源（按执行次数排序）

```sql
SELECT DIGEST_TEXT, PLAN_DIGEST, EXEC_COUNT, AVG_AFFECTED_ROWS
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%' ORDER BY EXEC_COUNT DESC LIMIT 5;
```

| DIGEST_TEXT | PLAN_DIGEST | EXEC_COUNT | AVG_AFFECTED_ROWS |
|-------------|-------------|------------|-------------------|
| `INSERT INTO t_diag ( ... ) VALUES ( ... )` | `a1b2c3...` | 200,001 | 1.0 |
| `UPDATE t_diag SET score = ? WHERE user_id = ? AND city = ?` | `d4e5f6...` | 45,000 | 1.0 |
| `SELECT * FROM t_diag WHERE city = ? AND score > ?` | `f7a8b9...` | 15,230 | 3,200.5 |
| `SELECT * FROM t_diag WHERE user_id = ? ORDER BY created_at DESC LIMIT ?` | `c0d1e2...` | 8,450 | 12.3 |
| `SELECT COUNT(*) FROM t_diag WHERE city = ? AND age BETWEEN ? AND ?` | `a3b4c5...` | 3,200 | 1.0 |

**分析**：`INSERT` 执行次数最高符合 OLTP 写入特征；但 `SELECT * FROM t_diag WHERE city = ? AND score > ?` 每次平均影响 3,200 行——大量行被扫描后过滤，效率低下。

---

### 3. 按 CPU 时间诊断（定位 CPU 瓶颈 SQL）

```sql
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_CPU_TIME_MS, SUM_CPU_TIME_MS
FROM information_schema.cluster_statements_summary
ORDER BY SUM_CPU_TIME_MS DESC LIMIT 5;
```

| DIGEST_TEXT | EXEC_COUNT | AVG_CPU_TIME_MS | SUM_CPU_TIME_MS |
|-------------|------------|-----------------|-----------------|
| `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` | 15,230 | 450.3 | 6,858,069 |
| `SELECT * FROM t_diag WHERE user_id = ? ORDER BY created_at DESC LIMIT ?` | 8,450 | 85.6 | 723,320 |
| `SELECT COUNT(*) FROM t_diag WHERE city = ? AND age BETWEEN ? AND ?` | 3,200 | 62.1 | 198,720 |
| `INSERT INTO t_diag (...)` | 200,001 | 0.3 | 60,000 |
| `UPDATE t_diag SET score = ?` | 45,000 | 0.2 | 9,000 |

**诊断结论**：第一条 `SELECT *` 的 `SUM_CPU_TIME_MS` 占全部 TOP5 的 87%。Dashboard TopSQL 面板会以时间轴柱状图呈现——凌晨 02:00-03:00 该 SQL 的 CPU 消耗突然飙升，与实际告警时间吻合。

---

### 4. 按内存使用诊断

```sql
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_MEM_USAGE, MAX_MEM_USAGE
FROM information_schema.cluster_statements_summary
ORDER BY MAX_MEM_USAGE DESC LIMIT 5;
```

| DIGEST_TEXT | EXEC_COUNT | AVG_MEM_USAGE(B) | MAX_MEM_USAGE(B) |
|-------------|------------|------------------|------------------|
| `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` | 15,230 | 52,428,800 | 209,715,200 |
| `SELECT * FROM t_diag WHERE user_id = ? ORDER BY created_at DESC LIMIT ?` | 8,450 | 4,194,304 | 16,777,216 |
| `SELECT COUNT(*) FROM t_diag WHERE city = ? AND age BETWEEN ? AND ?` | 3,200 | 1,048,576 | 2,097,152 |

**诊断结论**：`SELECT *` 查询每次平均消耗 50MB 内存，最高达到 200MB——因为需要将大量行加载到 TiDB Server 内存中再做处理。

---

### 5. 集群整体统计（Dashboard 概览页数据源）

```sql
SELECT
    COUNT(DISTINCT DIGEST_TEXT) AS unique_sql_templates,
    SUM(EXEC_COUNT) AS total_executions,
    ROUND(AVG(AVG_LATENCY), 2) AS overall_avg_latency_ms
FROM information_schema.cluster_statements_summary;
```

| 指标 | 值 | 说明 |
|------|-----|------|
| `unique_sql_templates` | 47 | 集群中共有 47 种不同的 SQL 模板 |
| `total_executions` | 302,450 | 自上次统计信息重置以来总执行次数 |
| `overall_avg_latency_ms` | 12.35 | 全局平均延迟 12.35ms（被大量快速的 INSERT/UPDATE 拉低，掩盖了慢查询） |

---

### 6. Dashboard 完整诊断路径

| 步骤 | Dashboard 模块 | 操作 | 对应 SQL / API | 发现 |
|------|---------------|------|---------------|------|
| **1** | **概览 (Overview)** | 查看集群整体 QPS、延迟、各节点状态 | `cluster_statements_summary` 聚合 | QPS 正常但 P99 延迟在凌晨飙升至 5s+ |
| **2** | **TopSQL** | 按 CPU 时间排序，选择凌晨 02:00-03:00 时间窗口 | `cluster_statements_summary ORDER BY SUM_CPU_TIME_MS` | 发现一条 `SELECT * FROM t_diag WHERE city = ?` 独占 87% CPU |
| **3** | **Slow Query** | 过滤凌晨时间段的慢查询 | `cluster_slow_query WHERE time BETWEEN ...` | 该 Digest 产生了 5 条慢查询，最长 8.2s |
| **4** | **Statement Analysis** | 点击该 Digest 查看详细统计 | `cluster_statements_summary WHERE digest = ?` | 平均影响 3,200 行/次，`SELECT *` 回表开销巨大 |
| **5** | **Key Visualizer** | 查看 `t_diag` 表的读写流量分布 | PD Region API | `idx_city` 索引对应的 Region 读取流量异常集中 |
| **6** | **Compare** | 对比前一天同一时段 | `cluster_statements_summary_history` | 前一天该 SQL 平均延迟仅 80ms——凌晨有部署或数据变更 |
| **7** | **Profiling** | 对问题 SQL 进行执行计划分析 | `EXPLAIN ANALYZE SELECT ...` | 使用 `idx_city` 后仍需回表取 `name, age, user_id`，回表行数 = 匹配行数 |

---

### 7. Dashboard vs MySQL Performance Schema 诊断对比

| 诊断需求 | TiDB Dashboard | MySQL Performance Schema |
|---------|---------------|-------------------------|
| **找消耗 CPU 最多的 SQL** | TopSQL 面板，一键盘出，时间轴可视化 | `sys.x$statement_analysis` 手动查询，无时间轴对比 |
| **找慢查询** | Slow Query 面板，支持 Digest 聚合 + 时间范围过滤 | `sys.statements_with_runtimes_in_95th_percentile` 手动查询 |
| **定位热点 Region** | Key Visualizer，热力图展示读写流量分布 | 无对应能力（MySQL 单机架构无 Region 概念） |
| **SQL 执行趋势对比** | Compare 面板，两个时间段并排对比 | 需要手动对 `events_statements_summary_by_digest` 做快照对比 |
| **活跃连接诊断** | 集成在 Overview，视觉化呈现 | `sys.processlist` / `sys.session` 表查询 |
| **SQL 模板级分析** | Statement Analysis，一键聚合同一 Digest 的所有执行 | `sys.statement_analysis` 功能类似但需手动查询 |
| **使用门槛** | 浏览器打开 Dashboard，点选操作 | 需要熟练掌握 sys schema、P_S 表结构和 SQL 编写 |
| **实时性** | TopSQL 实时采集（秒级刷新） | P_S 表为累积统计，实时性取决于采集频率 |
