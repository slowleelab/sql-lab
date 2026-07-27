-- bad.sql: 软删除查询无合适索引，全表扫描 + filesort
-- idx_author 只能定位 author_id，但 deleted_at IS NULL 和 ORDER BY created_at 无法利用
-- deleted_at IS NULL 在 idx_author 上无法过滤，需回表逐行判断；ORDER BY 触发 filesort
SELECT *
FROM t_document_soft
WHERE author_id = 12345
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
