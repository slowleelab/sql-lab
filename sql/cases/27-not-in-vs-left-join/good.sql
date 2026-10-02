-- good.sql: 改写为 LEFT JOIN ... IS NULL（反连接 Anti Join）
-- 优化器可用索引高效完成，且不受 NULL 值干扰
SELECT u.id, u.username
FROM t_user_check u
LEFT JOIN t_order_check o ON o.user_id = u.id
WHERE o.id IS NULL;
