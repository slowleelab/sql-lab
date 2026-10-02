-- good.sql: 查询汇总表，O(1) 完成统计
-- 汇总表 t_order_daily_stats 按天预聚合了订单数，
-- 查全部订单数只需对几百行汇总表求 SUM，无需扫描大表。
-- 注意：若需按 status 过滤，汇总表应增加 status 维度列。
SELECT SUM(order_count) AS total_count
FROM t_order_daily_stats;
