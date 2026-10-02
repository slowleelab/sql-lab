-- good.sql: 查询条件补全最左前缀列 user_id
-- 满足 (user_id, status, created_at) 的最左前缀，三列都能用到索引
-- type 为 ref，通过索引精确定位，无需全表扫描
SELECT id, user_id, order_no, status, amount, created_at
FROM t_order_latest
WHERE user_id = 12345
  AND status = 1
  AND created_at > '2026-01-01';
