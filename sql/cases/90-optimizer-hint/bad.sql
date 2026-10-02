-- bad.sql: 优化器可能误选 idx_status，导致 filesort
--
-- 问题分析：
--   1. 查询条件: WHERE user_id = 100 AND status = 1 ORDER BY created_at DESC LIMIT 10
--   2. 两个可选索引:
--      - idx_status(status): 能过滤 status=1，但无法利用索引有序性排序
--      - idx_user_created(user_id, created_at): 能过滤 user_id=100，且索引有序可直接排序
--   3. 优化器基于代价估算选择索引，当统计信息不准确时可能误选 idx_status
--   4. 选 idx_status 后: 扫描 status=1 的约 35 万行，回表过滤 user_id=100，再 filesort
--   5. 选 idx_user_created 后: 扫描 user_id=100 的约 10 行，索引有序直接取前 10 行
--
-- 实际执行时优化器的选择取决于统计信息和代价估算
-- 以下 EXPLAIN 展示误选 idx_status 的情况（可用 FORCE INDEX 模拟）

SELECT * FROM t_order
WHERE user_id = 100 AND status = 1
ORDER BY created_at DESC
LIMIT 10;
