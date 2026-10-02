-- good.sql: 传入字符串（加引号），类型匹配，走唯一索引
SELECT id, username, phone, email, status
FROM t_user
WHERE phone = '13800138000';
