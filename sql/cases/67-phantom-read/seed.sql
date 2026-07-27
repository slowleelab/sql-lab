-- ============================================================
-- 造数据: 10 万条交易日志，tx_amount 范围 1~10000
-- 制造间隙：amount 在 5000~6000 之间无数据，用于演示范围查询幻读
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_tx_log $$
CREATE PROCEDURE sp_seed_tx_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_amount DECIMAL(12,2);

    SET autocommit = 0;

    WHILE i < 100000 DO
        -- 金额避开 5000~6000 区间：1~4999 或 6001~10000
        IF RAND() < 0.5 THEN
            SET v_amount = ROUND(1 + RAND() * 4998, 2);       -- 1~4999
        ELSE
            SET v_amount = ROUND(6001 + RAND() * 3999, 2);    -- 6001~10000
        END IF;

        INSERT INTO t_transaction_log (tx_amount, created_at)
        VALUES (
            v_amount,
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_tx_log();
DROP PROCEDURE IF EXISTS sp_seed_tx_log;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_transaction_log;
-- 查看 amount=5000~6000 区间数据（应为空，存在间隙）
SELECT COUNT(*) AS gap_rows FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
-- 查看区间边界数据
SELECT id, tx_amount FROM t_transaction_log
WHERE tx_amount < 5000 ORDER BY tx_amount DESC LIMIT 3;
SELECT id, tx_amount FROM t_transaction_log
WHERE tx_amount > 6000 ORDER BY tx_amount ASC LIMIT 3;
