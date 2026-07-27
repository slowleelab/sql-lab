-- good.sql: TiDB Hint 合集 —— 精细控制执行计划

-- ============================================================
-- 1. USE_INDEX / IGNORE_INDEX: 强制选择或忽略指定索引
-- ============================================================
-- 强制走 idx_city（高选择性），跳过优化器默认的 idx_status
EXPLAIN SELECT /*+ USE_INDEX(t_hint_test, idx_city) */ * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' LIMIT 20;

-- 忽略低选择性索引 idx_status
EXPLAIN SELECT /*+ IGNORE_INDEX(t_hint_test, idx_status) */ * FROM t_hint_test WHERE status = 1 AND city = 'Beijing' LIMIT 20;

-- ============================================================
-- 2. HASH_JOIN / INL_JOIN / MERGE_JOIN: 指定 Join 算法
--    （本案例表为单表，演示 Hint 语法；实际用于多表 Join）
-- ============================================================

-- ============================================================
-- 3. HASH_AGG / STREAM_AGG: 指定聚合算法
-- ============================================================
-- HASH_AGG: 使用 Hash 聚合（默认，适合 group 数多的场景）
EXPLAIN SELECT /*+ HASH_AGG() */ city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;

-- STREAM_AGG: 使用流式聚合（需要输入按 group key 有序，适合 group 数少的场景）
EXPLAIN SELECT /*+ STREAM_AGG() */ city, COUNT(*), SUM(score) FROM t_hint_test GROUP BY city;

-- ============================================================
-- 4. READ_FROM_STORAGE: 指定从 TiKV 或 TiFlash 读取
-- ============================================================
-- 强制从 TiKV 读取（行存）
EXPLAIN SELECT /*+ READ_FROM_STORAGE(TIKV[t_hint_test]) */ city, COUNT(*) FROM t_hint_test GROUP BY city;

-- 如果有 TiFlash 副本，可指定从 TiFlash 读取（列存）
-- EXPLAIN SELECT /*+ READ_FROM_STORAGE(TIFLASH[t_hint_test]) */ city, COUNT(*) FROM t_hint_test GROUP BY city;

-- ============================================================
-- 5. MAX_EXECUTION_TIME: 设置查询最大执行时间（毫秒）
-- ============================================================
SELECT /*+ MAX_EXECUTION_TIME(5000) */ COUNT(*) FROM t_hint_test;

-- ============================================================
-- 6. SET_VAR Hint: 会话级设置仅对当前语句生效
-- ============================================================
-- 关闭聚合下推，强制在 TiDB Server 层聚合
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_agg_push_down=OFF) */ city, COUNT(*) FROM t_hint_test GROUP BY city;

-- 关闭 limit 下推，观察执行计划变化
EXPLAIN SELECT /*+ SET_VAR(tidb_opt_limit_push_down_threshold=0) */ * FROM t_hint_test WHERE city = 'Beijing' LIMIT 20;

-- ============================================================
-- 7. MEMORY_QUOTA: 设置单条查询的内存限额（字节）
-- ============================================================
SELECT /*+ MEMORY_QUOTA(1073741824) */ COUNT(*) FROM t_hint_test;  -- 1 GB

-- ============================================================
-- 8. 查看 Hint 相关系统变量
-- ============================================================
SHOW VARIABLES LIKE '%hint%';
