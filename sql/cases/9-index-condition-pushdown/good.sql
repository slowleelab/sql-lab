-- good.sql: 开启 ICP 后的查询（需先执行 setup-good.sql 开启 ICP）
-- name LIKE '张%' 条件下推到索引层，只对匹配行回表
SELECT id, phone_prefix, name, phone, city
FROM t_user_icp
WHERE phone_prefix = '1380' AND name LIKE '张%';
