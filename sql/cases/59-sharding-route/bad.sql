-- bad.sql: 不知道数据在哪个分片，UNION ALL 扫描所有分片
-- 应用层没有做路由计算，只能"广播"查询到所有分片
-- 4 个分片各扫描一次，实际只有 1 个分片有目标数据
-- 分片数越多，浪费越大。8 个分片就要扫 8 次，16 个分片扫 16 次
SELECT * FROM t_order_0 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_1 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_2 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_3 WHERE user_id = 100;
