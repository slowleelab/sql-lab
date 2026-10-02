-- bad.sql: 优化器默认选择可能不是最优

-- ============================================================
-- 场景1: 高选择性条件 + 低选择性条件组合
-- status=1 占 90%（低选择性），city='Beijing' 占约 10%（高选择性）
-- 优化器可能选择 idx_status 而非 idx_city，导致大量行扫描
-- ============================================================
EXPLAIN SELECT * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' ORDER BY score LIMIT 20;

-- ============================================================
-- 场景2: 聚合未下推
-- 默认情况下 GROUP BY 聚合在 TiDB Server 层执行（root task）
-- 所有 20 万行从 TiKV 拉取到 TiDB 层再聚合
-- ============================================================
EXPLAIN SELECT city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;

-- ============================================================
-- 场景3: 查看关键的优化器开关状态
-- ============================================================
SHOW VARIABLES LIKE 'tidb_opt_agg_push_down';
SHOW VARIABLES LIKE 'tidb_opt_distinct_agg_push_down';
SHOW VARIABLES LIKE 'tidb_opt_limit_push_down_threshold';
SHOW VARIABLES LIKE 'tidb_enable_chunk_rpc';
