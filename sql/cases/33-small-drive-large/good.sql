-- good.sql: 小表驱动大表
-- STRAIGHT_JOIN 强制 t_promotion_ref (5000行，过滤后~500行) 作为驱动表
-- 外层循环仅 500 次，每次去大表通过 idx_order_no 索引查找
-- 总查找次数: ~500 × 1(索引查找) = 500 次
SELECT STRAIGHT_JOIN
    o.id, o.order_no, o.amount, o.status, p.discount
FROM t_promotion_ref p
INNER JOIN t_order_big o ON o.order_no = p.order_no
WHERE p.promotion_id = 1;
