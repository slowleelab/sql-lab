-- good.sql: 游标分页（Keyset Pagination）
--
-- 原理:
--   用上一页最后一条记录的 (created_at, id) 作为游标，
--   通过 WHERE 条件直接定位到下一页的起始位置。
--   无需扫描并丢弃前 N 行，扫描行数恒定为 LIMIT 值。
--
--   bad 方案: LIMIT 1000000, 20 -> 扫描 1,000,020 行（丢弃 100 万行）
--   good 方案: WHERE created_at < 游标值 -> 只扫描 20 行
--
--   游标值来自上一页最后一条记录:
--     created_at = '2026-06-15 10:30:00', id = 123456

SELECT id, user_id, content, status, created_at
FROM t_feed
WHERE status = 1
  AND (created_at < '2026-06-15 10:30:00'
       OR (created_at = '2026-06-15 10:30:00' AND id < 123456))
ORDER BY created_at DESC, id DESC
LIMIT 20;
