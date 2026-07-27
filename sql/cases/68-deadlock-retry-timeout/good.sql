-- good.sql: 设置合理的 innodb_lock_wait_timeout + 短事务快速释放锁
-- 配合 setup-good.sql 设置 SET SESSION innodb_lock_wait_timeout=5（5秒超时）
-- 事务快速提交释放锁，超时后应用层捕获错误并重试
--
-- 优化后复现（配合 setup-good.sql）：
--
--   会话A（短事务）:
--     SET SESSION innodb_lock_wait_timeout=5;
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
--     COMMIT;  -- 快速提交，释放行锁
--
--   会话B（短超时+重试）:
--     SET SESSION innodb_lock_wait_timeout=5;
--     -- 若会话A仍持锁，5秒后超时，应用层捕获 1205 错误重试
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
--     COMMIT;

-- 短事务：快速提交释放锁，减少锁等待
BEGIN;

UPDATE t_concurrent_counter
SET counter_value = counter_value + 1, thread_id = 'session-B', updated_at = NOW()
WHERE id = 1;

COMMIT;
