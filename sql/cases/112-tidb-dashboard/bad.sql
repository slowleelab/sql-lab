-- bad.sql: TiDB Dashboard 诊断 — 定位问题的数据源查询

-- ============================================================
-- 场景：凌晨 CPU 飙升，需要通过 Dashboard 的诊断数据源定位根因
-- ============================================================

-- 1. 慢查询定位：查询集群慢 SQL 日志
SELECT * FROM information_schema.cluster_slow_query ORDER BY time DESC LIMIT 5;

-- 2. 查看当前活跃查询（长时间运行的 SQL 可能是瓶颈）
SELECT * FROM information_schema.cluster_processlist WHERE command != 'Sleep' AND time > 1;

-- 3. TopSQL 数据查询（Dashboard TopSQL 的数据来源）
-- statements_summary / statements_summary_history 按平均延迟排序
SELECT DIGEST_TEXT, SUM_EXEC_COUNT, AVG_LATENCY, MAX_LATENCY
FROM information_schema.cluster_statements_summary
ORDER BY AVG_LATENCY DESC LIMIT 5;

-- 4. 定位耗 CPU 的 SQL 类型（Dashboard TopSQL 按 CPU 排序的依据）
SELECT DIGEST_TEXT, AVG_CPU_TIME_MS, SUM_CPU_TIME_MS
FROM information_schema.cluster_statements_summary
ORDER BY SUM_CPU_TIME_MS DESC LIMIT 5;

-- 5. 查看消耗 CPU 最多的 SQL 模板（按总执行时间排序）
SELECT DIGEST_TEXT, EXEC_COUNT, AVG_TOTAL_KEYS, SUM_TOTAL_KEYS
FROM information_schema.cluster_statements_summary
WHERE DIGEST_TEXT LIKE '%t_diag%'
ORDER BY SUM_TOTAL_KEYS DESC LIMIT 5;

-- 6. 查看当前热点 Region（Key Visualizer 的数据源）
SELECT * FROM information_schema.tikv_region_status WHERE is_index = 0 LIMIT 5;

-- 7. 查看 TiKV 的热点读写统计
SHOW STATS_HEALTHY;
ANALYZE TABLE t_diag;
