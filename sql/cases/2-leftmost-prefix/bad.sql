-- bad.sql: 查询条件跳过了联合索引的最左列 user_id
-- 联合索引 idx_user_status_created (user_id, status, created_at) 要求满足最左前缀
-- 这里只用了 status 和 created_at，缺少 user_id，索引无法用于定位
-- 优化器只能全表扫描后逐行过滤
SELECT id, user_id, order_no, status, amount, created_at
FROM t_order_latest
WHERE status = 1
  AND created_at > '2026-01-01';
