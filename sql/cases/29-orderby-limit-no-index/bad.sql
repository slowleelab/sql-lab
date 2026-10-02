-- bad.sql: created_at 无索引，ORDER BY DESC LIMIT 需全表扫描 + filesort
SELECT id, user_id, content, created_at
FROM t_message
ORDER BY created_at DESC
LIMIT 10;
