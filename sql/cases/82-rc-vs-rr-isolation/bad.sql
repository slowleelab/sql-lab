-- bad.sql: RR 隔离级别下，范围查询 FOR UPDATE 加 next-key lock，阻塞并发插入
--
-- 问题分析：
--   1. RR 是 MySQL 默认隔离级别
--   2. SELECT ... WHERE user_id = 100 AND status = 1 FOR UPDATE
--      在 idx_user_status 索引上加 next-key lock
--   3. next-key lock = 记录锁 + 间隙锁，锁定 (100,1) 到 (100,2) 的整个区间
--   4. 其他事务向 user_id=100 插入新订单（无论 status 是什么）都会被阻塞
--   5. 因为新插入的 (100, 任意status) 都落在被锁定的间隙内
--
-- 复现步骤（需两个会话，RR 隔离级别，MySQL 默认）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;
--     -- 加锁：idx_user_status 上 (100,1) 到 (100,2) 的 next-key lock
--     -- 不提交，保持锁
--
--   会话B（被阻塞）:
--     BEGIN;
--     INSERT INTO t_order (order_no, user_id, amount, status)
--     VALUES ('NO999999', 100, 99.00, 0);
--     -- 被阻塞！等待会话A释放间隙锁
--     -- 超时后报错：ERROR 1205 (HY000): Lock wait timeout exceeded

-- 确认当前隔离级别（默认为 REPEATABLE-READ）
SELECT @@transaction_isolation;

BEGIN;

-- 范围查询加排他锁：RR 下锁定 user_id=100 的整个索引区间
SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;

-- 此时事务A持有 next-key lock，不 COMMIT，切换到会话B执行 INSERT 即可复现阻塞
