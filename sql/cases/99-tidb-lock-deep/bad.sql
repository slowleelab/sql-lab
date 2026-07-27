-- bad.sql: 普通 FOR UPDATE——获取不到锁时阻塞等待
-- 默认 innodb_lock_wait_timeout = 50s（TiDB 悲观模式下同样适用）

-- 会话A: 开启事务并对 id=1 加行锁
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- 会话A 持有 id=1 的行锁，尚未提交

-- 会话B: 执行同样的 SELECT FOR UPDATE，尝试获取同一行的锁
-- BEGIN;
-- SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- ❌ 阻塞等待会话A释放锁，最长等待 50 秒后超时报错：
--    ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction

-- 在锁等待期间（会话B阻塞时），从第三个会话查看锁等待信息：
SELECT * FROM information_schema.data_lock_waits;

-- 查看当前活跃连接及等待状态：
SELECT * FROM information_schema.cluster_processlist WHERE command != 'Sleep';

-- 问题总结：
-- 1. FOR UPDATE 在高并发下导致大量请求排队等待，吞吐急剧下降
-- 2. 连接池中的连接被长时间占用（等待锁），可能耗尽连接池
-- 3. 超时时间默认 50s，对在线业务来说太长——用户体感是"页面卡死"
