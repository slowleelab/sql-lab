-- good.sql: INNER JOIN 替代 LEFT JOIN
-- 业务确认: 已支付订单(status=1)一定存在对应用户，不存在孤儿订单
-- INNER JOIN 不保留任何一侧的未匹配行，优化器可自由选择驱动表
-- 优化器会评估: 从 t_user 过滤正常用户(9.5万) 驱动，还是从 t_order 过滤已支付(20万) 驱动
-- 最终选择代价更低的方案，外层循环次数大幅减少
SELECT o.id, o.order_no, o.amount, o.created_at, u.nickname
FROM t_order o
INNER JOIN t_user u ON o.user_id = u.id
WHERE o.status = 1;
