-- good.sql: 走联合索引 idx_author_deleted_created（需先执行 setup-good.sql 建索引）
-- (author_id, deleted_at, created_at) 三列联合索引完美覆盖查询:
--   author_id=12345 等值定位 -> deleted_at IS NULL 过滤 -> created_at 已按索引有序
-- 无需 filesort，LIMIT 20 可提前终止扫描
SELECT *
FROM t_document_soft
WHERE author_id = 12345
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
