-- bad.sql: 对索引列 created_at 施加 DATE() 函数，索引失效，退化为全表扫描
-- idx_created 索引无法被利用，因为 DATE(created_at) 是派生值，索引存的是原始 DATETIME
SELECT id, user_id, ip_addr, created_at
FROM t_access_log
WHERE DATE(created_at) = '2024-01-15';
