-- good.sql: 改写为 UNION ALL 两个独立查询
-- 将 OR 拆成两个独立查询，各自走自己的索引：
--   第一个查询走 idx_status，精确匹配 status=1 的行
--   第二个查询走 idx_city，精确匹配 city='北京' 的行
-- UNION ALL 不做去重（status=1 和 city='北京' 可能有交集，如需去重用 UNION），
-- 但避免了 index_merge 的合并排序开销，每个子查询独立高效执行。
-- 如果确认两个条件无交集，UNION ALL 是最佳选择；如有交集需去重，改用 UNION。
SELECT *
FROM t_user_merge
WHERE status = 1
UNION ALL
SELECT *
FROM t_user_merge
WHERE city = '北京'
  AND status != 1;
