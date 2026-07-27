-- good.sql: TiDB Dashboard 诊断链路及最佳实践

-- ============================================================
-- Dashboard 访问: http://127.0.0.1:2379/dashboard
-- 核心诊断模块:
--   Key Visualizer: 识别热点 Region 的读写流量分布
--   TopSQL: 按 CPU 时间排序，定位最耗资源的 SQL
--   Statement Analysis: 分析单个 SQL 模板的执行统计
--   Slow Query: 列出所有慢查询，支持时间范围过滤
--   Compare: 对比两个时间段的 SQL 执行变化趋势
-- ============================================================

-- 1. 启用 TopSQL 特性（确保流量捕获开启）
SHOW VARIABLES LIKE 'tidb_enable_top_sql';

-- 2. 查看 SQL Digest 统计（等同于 Dashboard Statement Analysis 的数据源）
--    按执行次数排序，找出最频繁执行的 SQL 模板
SELECT DIGEST_TEXT, PLAN_DIGEST, EXEC_COUNT, AVG_AFFECTED_ROWS
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%' ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 3. 查看 SQL 执行计划的统计信息（Plan Digest 维度）
--    同一 SQL 模板可能生成多个执行计划，找到计划不稳定的 SQL
SELECT DIGEST_TEXT, PLAN_DIGEST, EXEC_COUNT, AVG_LATENCY
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%'
ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 4. 查看历史 SQL 摘要（对比时间段变化，对应 Dashboard Compare 功能）
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_LATENCY, MAX_LATENCY
FROM information_schema.cluster_statements_summary_history
WHERE DIGEST_TEXT LIKE '%t_diag%'
ORDER BY EXEC_COUNT DESC LIMIT 5;

-- 5. 按 CPU 时间诊断：找出最消耗 CPU 的 SQL 模板
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_CPU_TIME_MS, SUM_CPU_TIME_MS
FROM information_schema.cluster_statements_summary
ORDER BY SUM_CPU_TIME_MS DESC LIMIT 5;

-- 6. 按内存使用诊断：找出内存消耗大的 SQL
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_MEM_USAGE, MAX_MEM_USAGE
FROM information_schema.cluster_statements_summary
ORDER BY MAX_MEM_USAGE DESC LIMIT 5;

-- 7. 查看 TiDB 集群的整体查询统计（Dashboard 概览页数据源）
SELECT
    COUNT(DISTINCT DIGEST_TEXT) AS unique_sql_templates,
    SUM(EXEC_COUNT) AS total_executions,
    ROUND(AVG(AVG_LATENCY), 2) AS overall_avg_latency_ms
FROM information_schema.cluster_statements_summary;

-- 8. Dashboard 对比 MySQL Performance Schema 诊断路径
-- Dashboard:              可视化界面 → 点选时间范围 → 自动聚合 Digest
-- MySQL Performance Schema: 需要手动编写 SQL 查询 sys schema + events_statements_summary
-- 详见 docs/cases/tidb/98-tidb-dashboard.md 的深入原理章节
