-- good.sql: 显式展开前导列 gender，让索引完全生效
-- 将查询改写为 WHERE gender IN ('M','F') AND created_at > '2026-01-01'，
-- 显式指定前导列 gender 的所有可能值，让联合索引 (gender, created_at) 完全生效。
-- 这样 MySQL 可以分别在 gender='M' 和 gender='F' 两个索引前缀下，
-- 利用 created_at 的范围扫描，避免全表扫描。
-- 在 MySQL 8.0 中，也可以直接使用原 SQL 让优化器选择 Skip Scan，
-- 但显式展开更可靠、执行计划更稳定。
SELECT *
FROM t_user_skip
WHERE gender IN ('M', 'F')
  AND created_at > '2026-01-01';
