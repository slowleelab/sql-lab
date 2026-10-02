-- bad.sql: 手机号字段是 VARCHAR(11)，但查询时传了数字（没加引号）
-- MySQL 会对 phone 列做隐式类型转换: CAST(phone AS SIGNED)
-- 这导致 uk_phone 索引完全失效，退化为全表扫描
SELECT id, username, phone, email, status
FROM t_user
WHERE phone = 13800138000;
