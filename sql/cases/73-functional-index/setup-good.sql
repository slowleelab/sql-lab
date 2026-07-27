-- setup-good.sql: 创建 8.0 函数索引，直接对 DATE(created_at) 表达式建索引
-- 创建后，原 bad.sql 的 WHERE DATE(created_at) = '...' 写法也能命中此索引
-- 注: 函数索引仅 MySQL 8.0.13+ 支持
ALTER TABLE t_access_log ADD KEY idx_date_created ((DATE(created_at)));
