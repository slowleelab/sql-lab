-- bad.sql: NOT IN 子查询查无订单用户
-- 子查询 SELECT user_id FROM t_order_check 物化为临时表，逐行匹配，性能差
SELECT id, username
FROM t_user_check
WHERE id NOT IN (SELECT user_id FROM t_order_check);
