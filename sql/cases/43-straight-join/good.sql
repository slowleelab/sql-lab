-- good.sql: STRAIGHT_JOIN 强制从 t_order 开始，先过滤 user_id
-- STRAIGHT_JOIN 强制 JOIN 顺序为 t_order -> t_order_item -> t_product：
--   1. 先从 t_order 过滤 user_id = 100（约 2 行）
--   2. 用这 2 行驱动 t_order_item（idx_order_id，约 6 行）
--   3. 用这 6 行驱动 t_product（主键，过滤 category='电子'）
-- 每步 JOIN 都用小结果集驱动，中间结果集始终很小。
SELECT *
FROM t_order_sj o
STRAIGHT_JOIN t_order_item_sj i ON o.id = i.order_id
STRAIGHT_JOIN t_product_sj p ON i.product_id = p.id
WHERE o.user_id = 100
  AND p.category = '电子';
