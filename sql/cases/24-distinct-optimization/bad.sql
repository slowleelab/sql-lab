-- bad.sql: DISTINCT user_id 去重，visit_time 过滤后无可用索引做有序扫描
-- Extra 出现 Using temporary（临时表去重）+ Using filesort
SELECT DISTINCT user_id
FROM t_visit_log
WHERE visit_time > '2024-01-01';
