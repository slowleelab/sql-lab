-- setup-good.sql: 创建降序索引（8.0 真正支持 DESC 索引列）
-- 5.7 会忽略 DESC 关键字，仍按 ASC 存储
ALTER TABLE t_event_log ADD KEY idx_type_created_desc (event_type, created_at DESC);
