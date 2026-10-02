-- bad.sql: 事务A的更新顺序（先更新订单1，再更新订单2）
-- 事务B的更新顺序相反（先更新订单2，再更新订单1），两者交叉加锁导致死锁
--
-- 时间线：
--   T1  事务A: BEGIN; UPDATE ... WHERE id=1;   -- 持有 id=1 行锁
--   T2  事务B: BEGIN; UPDATE ... WHERE id=2;   -- 持有 id=2 行锁
--   T3  事务A: UPDATE ... WHERE id=2;          -- 等待 id=2 行锁（被B持有）
--   T4  事务B: UPDATE ... WHERE id=1;          -- 等待 id=1 行锁（被A持有）=> 死锁！
--
-- 注意：本脚本仅展示事务A的语句。需在两个会话中分别按相反顺序执行才能复现死锁。
-- InnoDB 检测到死锁后会自动回滚其中一个事务（victim），报错 ERROR 1213 (40001)

BEGIN;

-- 事务A：先更新 id=1（顺序为 1 -> 2）
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 1;

-- 事务A：再更新 id=2
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 2;

COMMIT;
