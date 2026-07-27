-- good.sql: 使用 SELECT FOR UPDATE 加间隙锁防幻读，或配合 setup-good.sql 切到 SERIALIZABLE
-- 方案一：RR 下用 SELECT FOR UPDATE 加间隙锁，阻止其他事务向范围内插入
-- 方案二：SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE（自动加锁防幻读）
--
-- 防幻读复现（配合 setup-good.sql 切 SERIALIZABLE，或 RR 下用 FOR UPDATE）：
--
--   会话A:
--     BEGIN;
--     -- 加间隙锁，锁定 amount 5000~6000 范围
--     SELECT * FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
--     -- RR: 加 next-key lock，间隙 (5000,6000) 被锁
--     -- SERIALIZABLE: 普通 SELECT 也自动加锁
--
--   会话B:
--     INSERT INTO t_transaction_log (tx_amount) VALUES (5500.00);
--     -- ❌ 被阻塞！间隙锁阻止插入
--
--   会话A:
--     -- 再次查询，范围内行数不变
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0（无幻读）
--     COMMIT;

BEGIN;

-- 加锁读：锁定范围，防止其他事务插入幻影行
SELECT * FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;

-- 范围内行数保持一致，无幻读
SELECT COUNT(*) AS stable_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

COMMIT;
