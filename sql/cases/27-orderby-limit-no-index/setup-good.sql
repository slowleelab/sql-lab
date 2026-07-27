-- setup-good.sql: 给 created_at 建索引，ORDER BY 利用索引有序性
ALTER TABLE t_message ADD KEY idx_created (created_at);
