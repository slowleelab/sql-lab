-- good.sql: 同样查询，但被驱动表 order_id 已有索引（需先执行 setup-good.sql）
-- 加索引后走 Index Nested Loop Join: 驱动表过滤出少量行，每行通过 idx_order_id
-- 在被驱动表做一次索引查找，无需全表扫描。
SELECT o.id, o.amount, i.product_name
FROM t_order_main o
JOIN t_order_item i ON i.order_id = o.id
WHERE o.user_id = 5000;
