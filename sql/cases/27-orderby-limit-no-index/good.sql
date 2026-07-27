-- good.sql: 加索引 idx_created (created_at) 后，B+ 树有序直接取前 10 条
-- 需先执行 setup-good.sql 建立索引
SELECT id, user_id, content, created_at
FROM t_message
ORDER BY created_at DESC
LIMIT 10;
