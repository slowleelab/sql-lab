-- bad.sql: 用 COUNT(*) > 0 检查用户是否有未支付订单
-- 对每个用户都执行 COUNT(*) 子查询，统计该用户所有未支付订单的数量。
-- 即使用户有 100 个未支付订单，也要全部 COUNT 出来，效率低下。
-- 实际上只需要知道"是否存在"，不需要知道具体数量。
SELECT *
FROM t_user_exists u
WHERE (SELECT COUNT(*)
       FROM t_order_exists o
       WHERE o.user_id = u.id
         AND o.status = 0) > 0;
