-- bad.sql: 所有读查询都走主库，主库同时承担写入和读取压力
-- 高并发下读查询与写入争抢锁、CPU、Buffer Pool，互相拖慢
-- 生产环境中主库还可能因大量 SELECT 占用连接数导致写入排队
SELECT *
FROM t_order_master
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 20;
