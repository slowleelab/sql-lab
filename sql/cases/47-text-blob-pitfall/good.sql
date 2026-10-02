-- 只查必要列（不含 content），减少回表数据量
-- 不查 TEXT 字段时，InnoDB 回表读取聚簇索引行仍需定位到行数据，
-- 但不需要追踪 TEXT 溢出页链读取大文本内容，网络传输量也大幅减少
-- 进一步优化可将 views 放入覆盖索引实现完全 Using index（见 setup-good.sql）
SELECT id, title, author, category, views, created_at
FROM t_article
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
