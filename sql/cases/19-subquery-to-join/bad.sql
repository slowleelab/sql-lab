-- bad.sql: 用 IN 子查询查询"有订单的用户"
-- 5.7 上优化器可能将其作为相关子查询执行，对用户表每行去订单表扫描；
-- 即使 8.0 会自动改写为 semi-join，IN 子查询的写法仍不如 JOIN 直观可控。
SELECT *
FROM t_user_sub
WHERE id IN (SELECT user_id FROM t_order_sub);
