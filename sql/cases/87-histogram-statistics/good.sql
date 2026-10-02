-- good.sql: 创建直方图后，优化器知道 status=0 占 99%（选择性极差）
-- 从而选择 idx_user_created 通过 user_id 先精确定位（每个 user_id 约 100 行）
-- 同样查询，但需先执行 setup-good.sql 创建直方图
SELECT id, user_id, status, created_at
FROM t_task
WHERE status = 0
  AND user_id = 12345;
