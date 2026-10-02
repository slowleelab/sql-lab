-- good.sql: 用 UNION 改写 OR（需先执行 setup-good.sql 给 city 建索引）
-- 将 OR 拆成两个独立查询，各自走自己的索引：
--   第一个查询走 idx_phone
--   第二个查询走 idx_city
-- MySQL 对每个子查询分别选择最优索引，再合并去重结果
-- UNION 会自动去重；若确认无重复数据可用 UNION ALL 避免去重排序开销
SELECT id, username, phone, status, city, created_at
FROM t_user_or
WHERE phone = '13800138000'
UNION
SELECT id, username, phone, status, city, created_at
FROM t_user_or
WHERE city = '北京';
