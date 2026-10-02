-- good.sql: status 条件提前到 WHERE，只分组 25 万行
-- WHERE status = 1 在分组前过滤，只保留约 25 万行（status=1 占 1/4），
-- GROUP BY 只对这 25 万行做分组聚合，大幅减少分组计算量。
-- HAVING 只保留聚合条件 cnt > 5，职责清晰。
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM t_order_having
WHERE status = 1
GROUP BY user_id
HAVING cnt > 5;
