-- bad.sql: status 条件放在 HAVING 中，先分组 100 万行再过滤
-- GROUP BY user_id 会对全部 100 万行订单做分组聚合，
-- 然后 HAVING 才过滤 status=1 和 cnt>5，大量分组计算被浪费。
-- status 是行级条件，应该放在 WHERE 中提前过滤。
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM t_order_having
GROUP BY user_id
HAVING status = 1 AND cnt > 5;
