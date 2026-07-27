-- bad.sql: LEFT JOIN 查询已支付订单及用户信息
-- 业务上已支付订单一定有对应用户，LEFT JOIN 是多余的
-- LEFT JOIN 语义要求保留左表全部行，优化器必须以 t_order 为驱动表
-- 即使 t_user 过滤性更好，优化器也无法重排 JOIN 顺序
-- 结果: 外层循环 100 万次（全表扫描订单表），逐行去用户表查找
SELECT o.id, o.order_no, o.amount, o.created_at, u.nickname
FROM t_order o
LEFT JOIN t_user u ON o.user_id = u.id
WHERE o.status = 1;
