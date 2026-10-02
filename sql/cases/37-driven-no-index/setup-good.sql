-- setup-good.sql: 给被驱动表 t_order_item 的 JOIN 列 order_id 加索引
ALTER TABLE t_order_item ADD KEY idx_order_id (order_id);
