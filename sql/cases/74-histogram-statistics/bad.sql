-- bad.sql: 无直方图时，优化器认为 status=0 选择性好（基数低），可能选 idx_status
-- 但 status=0 实际占 99% 数据（约 19.8 万行），通过 idx_status 扫描后还要回表过滤 user_id
-- 选错索引导致大量无效回表
SELECT id, user_id, status, created_at
FROM t_task
WHERE status = 0
  AND user_id = 12345;
