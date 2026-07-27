-- bad.sql: 大 IN 列表查询
-- 模拟业务场景: 先从某处获取一批 user_id (1000个)，再用 IN 查询这些用户的订单。
-- 这里用子查询生成 1000 个去重 user_id，等价于一个含 1000 个常量的 IN 列表。
-- 问题:
--   1. IN 列表很大时，优化器解析和构建执行计划开销高
--   2. 大 IN 列表可能超出优化器的 range_max_rows 预估，导致执行计划不稳定
--   3. SQL 文本膨胀，网络传输和解析变慢，难以复用执行计划
SELECT *
FROM t_order_in
WHERE user_id IN (
    SELECT user_id
    FROM (SELECT DISTINCT user_id FROM t_order_in LIMIT 1000) tmp
);
