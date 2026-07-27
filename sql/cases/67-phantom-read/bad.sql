-- bad.sql: 普通快照读在事务中两次查询同一范围，演示幻读现象
-- RR 隔离级别下，普通 SELECT 是快照读，同一事务内读到的快照一致
-- 但当前读（UPDATE/DELETE/SELECT FOR UPDATE）会看到最新数据，导致幻读
--
-- 幻读复现（需两个会话，RR 隔离级别）：
--
--   会话A:
--     BEGIN;
--     -- 第一次查询：范围 5000~6000 内 0 行
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0
--
--   会话B:
--     INSERT INTO t_transaction_log (tx_amount) VALUES (5500.00);
--     COMMIT;
--
--   会话A:
--     -- 第二次普通 SELECT（快照读）：仍是 0（快照未变）
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0（快照读看不到新插入）
--
--     -- 但当前读会看到幻影行：
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
--     -- 结果：1（当前读看到会话B插入的 5500）=> 幻读！
--
--     -- 或 UPDATE 触发当前读：
--     UPDATE t_transaction_log SET tx_amount = tx_amount WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- Rows matched: 1（看到了幻影行）
--     COMMIT;

BEGIN;

-- 第一次查询：范围内行数
SELECT COUNT(*) AS first_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

-- （此时在会话B插入一行 amount=5500 并 COMMIT）
-- 第二次查询（普通快照读）：仍是旧快照
SELECT COUNT(*) AS second_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

-- 第三次查询（当前读 FOR UPDATE）：看到幻影行 -> 幻读
SELECT COUNT(*) AS current_read_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;

COMMIT;
