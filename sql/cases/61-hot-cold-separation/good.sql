-- 冷热分离后查询热表：热表仅 5 万行，数据常驻 Buffer Pool 缓存
-- 绝大多数用户查询的是近期订单，直接命中热表，查询极快
-- 需要查历史时再查冷表，或用 UNION ALL 合并两表结果
SELECT * FROM t_order_hot
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;
