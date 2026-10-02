-- good.sql: 缩小锁范围或使用 RC 隔离级别避免间隙锁
-- 方案一：精确等值查询 FOR UPDATE，只锁定命中的行（记录锁），不加间隙锁
-- 方案二：配合 setup-good.sql 切换到 RC 隔离级别，消除间隙锁
--
-- 复现验证（配合 setup-good.sql 切到 RC）：
--
--   会话A: SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
--          BEGIN;
--          SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
--          -- RC 下只加记录锁（id=10, id=20），不加间隙锁
--
--   会话B: BEGIN;
--          INSERT INTO t_account (id, account_no, balance) VALUES (15, 'ACC0015', 500.00);
--          -- ✅ 插入成功！不受阻塞（间隙未被锁）

BEGIN;

-- 精确等值查询加锁：只锁 id=10 这一行（记录锁），不影响间隙插入
SELECT * FROM t_account WHERE id = 10 FOR UPDATE;

COMMIT;
