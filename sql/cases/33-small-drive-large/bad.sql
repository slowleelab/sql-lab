-- bad.sql: 大表驱动小表（驱动表选错）
-- STRAIGHT_JOIN 强制 t_order_big (20万行) 作为驱动表
-- 外层循环 20 万次，每次去小表通过 idx_order_no 索引查找
-- 虽然 JOIN 列有索引，但 20 万次驱动循环远大于小表驱动的 500 次
SELECT STRAIGHT_JOIN
    o.id, o.order_no, o.amount, o.status, p.discount
FROM t_order_big o
INNER JOIN t_promotion_ref p ON p.order_no = o.order_no
WHERE p.promotion_id = 1;
