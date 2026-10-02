-- bad.sql: 常见的深度分页写法
-- 翻到第 10 万页（每页 20 条），OFFSET = 100000 * 20 = 2000000
-- MySQL 需要扫描并丢弃前 200 万行，再返回 20 行
SELECT id, user_id, order_no, amount, status, created_at
FROM t_order
WHERE status = 1
ORDER BY created_at DESC
LIMIT 2000000, 20;
