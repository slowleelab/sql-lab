-- good.sql: 建立联合索引 (user_id, visit_time) 后走 Using index for group-by
-- 需先执行 setup-good.sql 建立索引
SELECT DISTINCT user_id
FROM t_visit_log
WHERE visit_time > '2024-01-01';
