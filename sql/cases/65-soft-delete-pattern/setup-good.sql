-- setup-good.sql: 为软删除查询设计联合索引
-- (author_id, deleted_at, created_at) 覆盖 WHERE + ORDER BY，避免 filesort
-- author_id 等值定位 -> deleted_at IS NULL 过滤 -> created_at 已有序（省去排序）
ALTER TABLE t_document_soft
    ADD KEY idx_author_deleted_created (author_id, deleted_at, created_at);
