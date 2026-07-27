-- bad.sql: JOIN 时被驱动表 t_order_item 的 order_id 列无索引
-- 5.7: 退化为 Block Nested Loop，对驱动表每行都全表扫描 t_order_item (30万行)
-- 8.0: 走 Hash Join 兜底，比 BNL 好但仍需构建哈希表、全扫两表
-- 驱动表 t_order_main 通过 idx_user_id 过滤出少量行，但被驱动表无索引放大开销
SELECT o.id, o.amount, i.product_name
FROM t_order_main o
JOIN t_order_item i ON i.order_id = o.id
WHERE o.user_id = 5000;
