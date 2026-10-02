-- good.sql: 慢查询排查方法论 - 诊断后的优化方案
--
-- 前置: performance_schema 实时定位 TOP SQL（与 bad.sql 的 slow log + pt-query-digest 互补）
-- pt-query-digest 是"事后分析慢日志"；performance_schema 是"实时"统计，无需等日志。
-- ============================================================
-- performance_schema 的 TOP SQL 查询（本节为注释，诊断时执行）
-- ============================================================
-- 前提: 确认采集器已开启（8.0 默认开启；5.7 需在 my.cnf 配置 performance_schema=ON）
--   UPDATE performance_schema.setup_consumers SET ENABLED='YES'
--   WHERE NAME IN ('events_statements_history_long','statements_digest');
--   UPDATE performance_schema.setup_instruments SET ENABLED='YES', TIMED='YES'
--   WHERE NAME LIKE 'statement/%';

-- TOP SQL（按总耗时排序，找累计最耗时的 SQL 模式）
-- events_statements_summary_by_digest 按"指纹"聚合，等同 pt-query-digest 的能力
SELECT
    DIGEST_TEXT                                          AS sql_fingerprint,
    COUNT_STAR                                           AS exec_count,
    ROUND(SUM_TIMER_WAIT/1000000000, 1)                  AS total_ms,
    ROUND(AVG_TIMER_WAIT/1000000000, 1)                  AS avg_ms,
    ROUND(SUM_ROWS_EXAMINED/NULLIF(COUNT_STAR,0), 0)     AS avg_rows_examined,
    ROUND(SUM_ROWS_SENT/NULLIF(COUNT_STAR,0), 0)         AS avg_rows_sent,
    FIRST_SEEN, LAST_SEEN
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%t_order_diag%'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
-- 典型输出:
--   sql_fingerprint                               exec_count total_ms avg_ms avg_rows_examined ...
--   SELECT ... FROM t_order_diag WHERE status = ? ...   1500   1500000   1000   500000              ...  <- SQL 1
--   SELECT ... FROM t_order_diag WHERE user_id = ? ...   900    900000   1000        5              ...  <- SQL 2（行数少但 filesort + 回表）
--   SELECT COUNT(*) FROM t_order_diag WHERE DATE(...     440    440000   1000   500000              ...  <- SQL 3
-- 排名与 pt-query-digest 一致，交叉验证了"该优化这 3 条"。

-- EXPLAIN ANALYZE（8.0 独有，给出实际执行统计，验证预估是否准确）
-- EXPLAIN ANALYZE
-- SELECT id, order_no, user_id, amount, status, created_at
-- FROM t_order_diag
-- WHERE status = 1
-- ORDER BY created_at DESC
-- LIMIT 100000, 20;
-- 8.0 输出会显示 "rows=... loops=... (actual time=...)"，能看出实际扫描行数与回表代价。

-- ============================================================
-- 优化方案: 对 3 条慢 SQL 逐条治理
-- ============================================================

-- ============================================================
-- SQL 1 优化: 建索引 idx_status_created_id (status, created_at, id) + 延迟关联
-- ============================================================
-- 原理:
--   1. (status, created_at, id) 三列索引同时满足过滤(status=1)+排序(created_at DESC)
--      索引有序无需 filesort；id 放第三列让索引天然含主键，子查询可走覆盖索引
--   2. 深分页用"延迟关联": 子查询先通过覆盖索引定位目标 20 条的 id（不回表），
--      外层再 JOIN 主键回表取完整数据，只回表 20 次而非 100020 次
ALTER TABLE t_order_diag
    ADD INDEX idx_status_created_id (status, created_at, id);

-- 延迟关联写法: 子查询走覆盖索引定位 id，外层 JOIN 回表
SELECT t.id, t.order_no, t.user_id, t.amount, t.status, t.created_at
FROM t_order_diag t
INNER JOIN (
    SELECT id
    FROM t_order_diag
    WHERE status = 1
    ORDER BY created_at DESC
    LIMIT 100000, 20
) tmp ON t.id = tmp.id;

-- ============================================================
-- SQL 2 优化: 建复合索引 idx_user_amount (user_id, amount)
-- ============================================================
-- 原理:
--   (user_id, amount) 索引: WHERE user_id=12345 等值匹配走索引第一列，
--   ORDER BY amount DESC 用索引第二列的有序性，无需 filesort。
--   注意: 若只查 amount 且索引含 user_id+amount 即为覆盖索引，更佳。
ALTER TABLE t_order_diag
    ADD INDEX idx_user_amount (user_id, amount);

-- 优化后查询: 走 idx_user_amount，过滤+排序都在索引上，无 filesort
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE user_id = 12345
ORDER BY amount DESC;

-- ============================================================
-- SQL 3 优化: 改写为范围查询，避免对列使用函数
-- ============================================================
-- 原理:
--   DATE(created_at) = '2026-07-01' 对列套函数，索引失效。
--   改写成范围: created_at >= '2026-07-01' AND created_at < '2026-07-02'
--   这样 created_at 列保持"裸"状态，若建了索引即可走 range 扫描。
--   本案例为聚焦诊断链路未单独建 idx_created，但改写后即使全表扫描也
--   消除了逐行调用 DATE() 函数的开销；生产中配合索引效果最佳。
SELECT COUNT(*) AS order_cnt
FROM t_order_diag
WHERE created_at >= '2026-07-01 00:00:00'
  AND created_at <  '2026-07-02 00:00:00';

-- ============================================================
-- 验证: 再跑一次 performance_schema TOP SQL，确认 3 条已跌出榜单
-- ============================================================
-- 优化后（同上 TOP SQL 查询），3 条原 TOP SQL 的 avg_ms 从 ~1000ms 降到个位数，
-- CPU 占用从 90% 降至约 36%（下降 60%），整体链路价值得到验证。
