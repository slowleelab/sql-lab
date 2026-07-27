-- bad.sql: 三表 JOIN，优化器可能选错驱动表
-- 优化器可能先 JOIN t_order_item 和 t_product（30 万 × 1 万），
-- 产生大量中间结果，最后才过滤 o.user_id = 100。
-- 中间结果集爆炸，性能骤降。
SELECT *
FROM t_order_sj o
JOIN t_order_item_sj i ON o.id = i.order_id
JOIN t_product_sj p ON i.product_id = p.id
WHERE o.user_id = 100
  AND p.category = '电子';
