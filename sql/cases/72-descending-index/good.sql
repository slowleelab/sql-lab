-- good.sql: 建立降序索引 idx_type_created_desc (event_type, created_at DESC)
-- 需先执行 setup-good.sql 创建降序索引，8.0 真正按 DESC 存储索引，消除 filesort
SELECT id, event_type, event_data, created_at
FROM t_event_log
WHERE event_type = 'LOGIN'
ORDER BY created_at DESC
LIMIT 20;
