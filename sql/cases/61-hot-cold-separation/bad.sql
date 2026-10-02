-- 查询冷表（模拟单表大表场景）：冷表 15 万行，数据量大、缓存命中率低
-- 生产环境中如果不分离，所有数据在一张大表里，热查询也会被冷数据拖慢
-- 这里直接查冷表模拟"大表查历史"的慢查询场景
SELECT * FROM t_order_cold
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;
