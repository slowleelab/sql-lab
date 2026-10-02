-- good.sql: 按一致的加锁顺序更新（总是先更新 id 小的，再更新 id 大的）
-- 事务A和事务B都遵循 1 -> 2 的顺序，不会形成循环等待，避免死锁
--
-- 时间线：
--   T1  事务A: BEGIN; UPDATE ... WHERE id=1;   -- 持有 id=1 行锁
--   T2  事务B: BEGIN; UPDATE ... WHERE id=1;   -- 等待 id=1 行锁
--   T3  事务A: UPDATE ... WHERE id=2;          -- 持有 id=2 行锁
--   T4  事务A: COMMIT;                         -- 释放 id=1、id=2 行锁
--   T5  事务B: 获取 id=1 行锁，UPDATE id=1 完成
--   T6  事务B: UPDATE ... WHERE id=2;
--   T7  事务B: COMMIT;
--   => 事务A先执行完，事务B串行等待，无死锁
--
-- 复现说明：在两个会话中分别执行下面的语句（按相同顺序），不会死锁，只会等待

BEGIN;

-- 总是先更新 id 小的行
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 1;

-- 再更新 id 大的行
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 2;

COMMIT;
