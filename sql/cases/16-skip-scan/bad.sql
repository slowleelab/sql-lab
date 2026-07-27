-- bad.sql: 查询 created_at > '2026-01-01'，跳过前导列 gender
-- 联合索引 (gender, created_at) 的前导列是 gender，但查询条件只涉及 created_at。
-- MySQL 5.7 无法使用该索引，只能全表扫描。
-- MySQL 8.0 虽然支持 Skip Scan，但优化器不一定总是选择它（取决于统计信息），
-- 且 Skip Scan 的效率不如直接使用前导列。
SELECT *
FROM t_user_skip
WHERE created_at > '2026-01-01';
