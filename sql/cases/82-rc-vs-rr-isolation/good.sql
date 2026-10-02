-- good.sql: RC 隔离级别下，同样的查询只加记录锁，不锁间隙，并发插入不被阻塞
--
-- 优化原理：
--   1. RC（READ COMMITTED）隔离级别下，InnoDB 只加记录锁（Record Lock）
--   2. 不加间隙锁（Gap Lock），因此不会阻塞其他事务向间隙插入数据
--   3. 同样的 SQL，在 RC 下并发插入不受影响
--
-- 复现验证（配合 setup-good.sql 切到 RC）：
--
--   会话A: SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
--          BEGIN;
--          SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;
--          -- RC 下只加记录锁（命中的行），不加间隙锁
--
--   会话B: BEGIN;
--          INSERT INTO t_order (order_no, user_id, amount, status)
--          VALUES ('NO999999', 100, 99.00, 0);
--          -- 插入成功！不受阻塞（间隙未被锁）

-- 确认当前隔离级别（需先执行 setup-good.sql 切换到 RC）
SELECT @@transaction_isolation;

BEGIN;

-- 同样的查询，RC 下只锁命中的行，不锁间隙
SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;

-- 此时事务A只持有记录锁，切换到会话B执行 INSERT 不会被阻塞
