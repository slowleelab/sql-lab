-- bad.sql: 关闭 ICP 后的查询（需先执行 setup-bad.sql 关闭 ICP）
-- phone_prefix=1380 匹配约 4 万行，关闭 ICP 后全部回表再用 name LIKE 过滤
SELECT id, phone_prefix, name, phone, city
FROM t_user_icp
WHERE phone_prefix = '1380' AND name LIKE '张%';
