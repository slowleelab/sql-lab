-- good.sql: 应用层先做路由计算，精确查询目标分片
-- 路由规则: shard = user_id % 4
-- user_id = 100 -> 100 % 4 = 0 -> 目标分片是 t_order_0
-- 只查 1 个分片，性能与单表查询完全一致
-- 分片数再多也不影响单次查询性能
SELECT * FROM t_order_0 WHERE user_id = 100;
