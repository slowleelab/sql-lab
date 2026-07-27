-- good.sql: 改写为 INNER JOIN + DISTINCT
-- 优化器可用 idx_user_id 索引做高效的等值 JOIN，
-- DISTINCT 消除重复用户行，避免对子查询的依赖。
SELECT DISTINCT u.*
FROM t_user_sub u
INNER JOIN t_order_sub o ON u.id = o.user_id;
