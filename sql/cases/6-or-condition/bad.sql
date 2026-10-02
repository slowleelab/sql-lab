-- bad.sql: OR 连接两个条件，其中 city 列无索引
-- phone='13800138000' 可走 idx_phone，但 city='北京' 无索引
-- OR 要求两侧都能快速定位才能用 index_merge，只要一侧需要全表扫描，
-- 优化器就会直接放弃索引，整体走全表扫描
SELECT id, username, phone, status, city, created_at
FROM t_user_or
WHERE phone = '13800138000'
   OR city = '北京';
