-- bad.sql: LIMIT OFFSET 深分页
-- 用户翻到第 5 万页（每页 20 条），OFFSET = 50000 * 20 = 1000000
-- MySQL 必须扫描并丢弃前 100 万行，再返回 20 行
-- 越往后翻越慢，性能随页深度线性退化
SELECT id, user_id, content, status, created_at
FROM t_feed
WHERE status = 1
ORDER BY created_at DESC, id DESC
LIMIT 1000000, 20;
