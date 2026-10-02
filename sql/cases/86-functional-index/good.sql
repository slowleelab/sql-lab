-- good.sql: 改写为范围查询，避免对索引列施加函数，可走 idx_created 范围扫描
-- 也可用 setup-good.sql 的函数索引 ((DATE(created_at))) 直接支持原写法
SELECT id, user_id, ip_addr, created_at
FROM t_access_log
WHERE created_at >= '2024-01-15 00:00:00'
  AND created_at <  '2024-01-16 00:00:00';
