-- bad.sql: 乐观事务模式下的 Write Conflict

-- 设置乐观事务模式
SET SESSION tidb_txn_mode = 'optimistic';

-- 事务A (模拟第一个会话)
BEGIN;
UPDATE t_account SET balance = balance - 1000 WHERE id = 1;
-- 此时不持有锁，其他事务可以同时修改同一行

-- 事务B (模拟第二个会话——在另一个终端执行)
-- BEGIN;
-- UPDATE t_account SET balance = balance - 500 WHERE id = 1;  -- 乐观模式下不会阻塞
-- COMMIT;  -- 事务B先提交成功

-- 回到事务A
-- COMMIT;  -- Write Conflict! 事务A的提交被拒绝，需要客户端重试

-- 查看乐观事务的重试限制
SHOW VARIABLES LIKE 'tidb_retry_limit';

-- 查看当前事务模式
SELECT @@tidb_txn_mode;
