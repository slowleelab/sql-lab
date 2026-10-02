-- bad.sql: 仅有升序索引 idx_type_created (event_type, created_at)
-- ORDER BY created_at DESC 需要逆向扫描，5.7 不支持降序索引导致 filesort
-- （若已执行 setup-good.sql 添加了降序索引，请先重建表后再测试本 bad 场景）
SELECT id, event_type, event_data, created_at
FROM t_event_log
WHERE event_type = 'LOGIN'
ORDER BY created_at DESC
LIMIT 20;
