-- good.sql: 三种反模式的正确写法

-- ============================================================
-- 正解 1: 只查必要列，走覆盖索引避免回表
-- id, user_id 两个列都在 idx_user 索引中（InnoDB 二级索引自动附加主键 id），
-- 虽然 amount 不在索引中仍需回表，但避免了 SELECT * 读取 remark 等
-- 不需要的列，回表读取的数据量大幅减少。
-- 若只需 id 和 user_id，则完全走覆盖索引（Using index），零回表。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000;

-- ============================================================
-- 正解 2: UNION ALL 拆分 OR 条件
-- 将 OR 拆为两个独立查询，每个查询都能高效走单一索引：
-- 第一段走 idx_user(user_id=5000)，约 30 行；
-- 第二段走 idx_status(status=1 AND user_id!=5000)，虽然 status=1 行多，
-- 但 UNION ALL 让优化器对两段分别选择最优索引，避免 index_merge 合并开销。
-- 两段结果无交集（第二段排除 user_id=5000），用 UNION ALL 无需去重。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000
UNION ALL
SELECT id, user_id, amount FROM t_anti_test WHERE status = 1 AND user_id != 5000;

-- ============================================================
-- 正解 3: COUNT(*) 统计总行数
-- COUNT(*) 统计匹配条件的全部行数（包括 remark 为 NULL 的行），语义正确。
-- InnoDB 对 COUNT(*) 有特殊优化：选择最小的索引扫描计数，
-- 且不读取行数据（只数索引条目），比 COUNT(col) 更高效。
-- ============================================================
SELECT COUNT(*) FROM t_anti_test WHERE user_id = 5000;
