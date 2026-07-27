-- bad.sql: RR隔离级别下范围查询 FOR UPDATE 加间隙锁，阻塞插入
-- 事务A对 id BETWEEN 10 AND 20 加范围锁，会锁定间隙 (10, 20)
-- 事务B尝试 INSERT id=15（落在间隙内）会被阻塞直到超时
--
-- 复现步骤（需两个会话，RR 隔离级别，MySQL 默认）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
--     -- 加锁：id=10 记录锁 + (10,20) 间隙锁 + id=20 next-key锁
--     -- 不提交，保持锁
--
--   会话B（被阻塞）:
--     BEGIN;
--     INSERT INTO t_account (id, account_no, balance) VALUES (15, 'ACC0015', 500.00);
--     -- ❌ 被阻塞！等待会话A释放间隙锁
--     -- 超时后报错：ERROR 1205 (HY000): Lock wait timeout exceeded

BEGIN;

-- 范围查询加排他锁：锁定 [10, 20] 区间及间隙 (10,20)
SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;

-- 此时事务A持有间隙锁，不 COMMIT，切换到会话B执行 INSERT 即可复现阻塞
