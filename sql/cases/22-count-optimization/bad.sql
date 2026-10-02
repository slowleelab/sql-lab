-- bad.sql: 对大表做 COUNT(*) 统计已支付订单数
-- status 有索引，但仍需扫描索引所有 status=1 的条目逐行计数
-- 随数据增长，扫描行数线性增加，统计接口越来越慢
SELECT COUNT(*) AS paid_count
FROM t_order_count
WHERE status = 1;
