-- bad.sql: 联合索引 (user_id, status, amount)，status 用了范围查询 status>1
-- 联合索引中，范围查询列之后的列无法继续参与索引过滤
-- 这里 user_id(等值) -> status(范围) 可用索引，但 amount 在 status 之后且 status 是范围
-- amount>500 只能在回表后逐行过滤，无法利用索引缩小扫描范围
SELECT id, user_id, status, amount, created_at
FROM t_order_range
WHERE user_id = 1000
  AND status > 1
  AND amount > 500;
