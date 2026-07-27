-- bad.sql: 长事务 — 先加锁再执行耗时操作，锁持有时间过长
--
-- 问题分析：
--   1. SELECT ... FOR UPDATE 对 id=1 加排他锁（记录锁）
--   2. SLEEP(5) 模拟调用外部支付接口（耗时 5 秒）
--   3. 整个事务期间（5 秒+），id=1 的行锁一直被持有
--   4. 其他事务要更新 id=1 必须等待，造成锁等待堆积
--   5. 长事务还会导致 undo log 无法 purge，MVCC 快照链过长
--
-- 复现步骤（需两个会话）：
--   会话A: 执行本脚本（持锁 5 秒）
--   会话B: UPDATE t_account SET balance = balance - 50 WHERE id = 1;
--          -- 被阻塞约 5 秒，直到会话A COMMIT

BEGIN;

-- 第1步：加锁（排他锁，锁定 id=1）
SELECT * FROM t_account WHERE id = 1 FOR UPDATE;

-- 第2步：模拟耗时操作（如调用外部支付接口、发送短信通知等）
-- 实际场景中可能是 RPC 调用、HTTP 请求、文件 IO 等
SELECT SLEEP(5);

-- 第3步：扣减余额
UPDATE t_account SET balance = balance - 100 WHERE id = 1;

COMMIT;
