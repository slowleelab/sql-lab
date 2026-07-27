-- bad.sql: 三种常见 SQL 反模式

-- ============================================================
-- 反模式 1: SELECT * 导致回表
-- 即使 WHERE 走了 idx_user 索引定位到行，SELECT * 要求返回所有列，
-- 而索引中只含 user_id + id，order_no/amount/status/remark/created_at
-- 都不在索引中，必须逐行回表到聚簇索引读取完整行，无法走覆盖索引。
-- 30 万行表中 user_id=5000 约匹配 30 行，每行都需回表。
-- ============================================================
SELECT * FROM t_anti_test WHERE user_id = 5000;

-- ============================================================
-- 反模式 2: OR 条件可能导致 index_merge（低效）
-- WHERE user_id=5000 OR status=1，两个条件各自有索引 idx_user 和 idx_status。
-- 优化器选择 index_merge(union)：分别扫描两个索引，再合并去重。
-- status=1 匹配约 7.5 万行（占 25%），合并后结果集巨大，
-- index_merge 的合并去重开销 + 大量回表，远不如拆分为 UNION ALL。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000 OR status = 1;

-- ============================================================
-- 反模式 3: COUNT(col) 语义错误
-- COUNT(remark) 统计的是 remark 列非 NULL 的行数，而非匹配条件的总行数。
-- 约 20% 的行 remark 为 NULL，COUNT(remark) 会漏掉这些行，
-- 得到的数字小于实际匹配行数，语义错误。
-- 且 COUNT(col) 无法享受 InnoDB 对 COUNT(*) 的优化（如仅扫描最小索引）。
-- ============================================================
SELECT COUNT(remark) FROM t_anti_test WHERE user_id = 5000;
