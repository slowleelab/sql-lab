-- bad.sql: LIKE 使用前导通配符 '%zhang%'
-- 前导 % 使 B+ 树无法确定扫描起点，idx_username 索引失效，退化为全表扫描
-- 需逐行扫描 username 做子串匹配
SELECT id, username, nickname, phone, created_at
FROM t_user_search
WHERE username LIKE '%zhang%';
