-- good.sql: 悲观事务模式——与 MySQL 行为一致

-- 设置悲观事务模式（TiDB 6.0+ 默认）
SET SESSION tidb_txn_mode = 'pessimistic';

-- 事务A (模拟第一个会话)
BEGIN;
UPDATE t_account SET balance = balance - 1000 WHERE id = 1;
-- 悲观模式下此行已被锁定，其他事务必须等待

-- 事务B (模拟第二个会话——在另一个终端执行)
-- BEGIN;
-- UPDATE t_account SET balance = balance - 500 WHERE id = 1;  
-- 阻塞等待事务A释放锁（默认 innodb_lock_wait_timeout = 50s）
-- COMMIT;

-- 事务A提交后事务B继续执行
-- COMMIT;  -- 成功

-- 事务选择对比
SELECT '悲观事务' AS mode, '写入时加锁，提交即成功' AS behavior
UNION ALL
SELECT '乐观事务', '提交时检测冲突，失败需重试';

-- AS OF TIMESTAMP 历史读（TiDB 特有功能）
SELECT @@tidb_snapshot;
-- SET @@tidb_snapshot = '2026-07-01 00:00:00';
-- SELECT * FROM t_account;  -- 读取历史快照
-- SET @@tidb_snapshot = '';
