-- bad.sql: 长事务持锁不释放，另一事务等待超时
-- 事务A开启长事务持有行锁（模拟慢操作/忘记提交），事务B等待超时报错
--
-- 超时复现（需两个会话，默认 innodb_lock_wait_timeout=50 秒）：
--
--   会话A（长事务持锁）:
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value = counter_value + 1 WHERE id = 1;
--     -- 持有 id=1 行锁，不 COMMIT（模拟长事务/慢操作/网络延迟）
--     -- 此时执行其他慢操作（如远程调用、大查询），锁不释放
--
--   会话B（等待超时）:
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value = counter_value + 1 WHERE id = 1;
--     -- ❌ 等待 id=1 行锁，默认 50 秒后超时
--     -- ERROR 1205 (HY000): Lock wait timeout exceeded;
--     --   try restarting transaction
--
-- 问题：默认超时 50 秒太长，连接资源被长时间占用，应用层无重试逻辑

BEGIN;

-- 长事务：更新后不提交，模拟持锁不释放
UPDATE t_concurrent_counter
SET counter_value = counter_value + 1, thread_id = 'session-A', updated_at = NOW()
WHERE id = 1;

-- 此处省略慢操作（远程调用/大查询），行锁持续持有
-- 会话B 此时 UPDATE id=1 会等待超时

-- 故意不 COMMIT（演示问题，实际应在 good.sql 中缩短事务）
