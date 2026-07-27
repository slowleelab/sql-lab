-- ============================================================
-- 造数据: 50 万行订单数据（模拟生产 500 万行大表）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_instant_col $$
CREATE PROCEDURE sp_seed_instant_col()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 500000 DO
        INSERT INTO t_order (order_no, user_id, amount, status, created_at)
        VALUES (
            CONCAT('NO', LPAD(i, 10, '0')),
            FLOOR(1 + RAND() * 100000),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                     - INTERVAL FLOOR(RAND() * 24) HOUR
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

CALL sp_seed_instant_col();
DROP PROCEDURE IF EXISTS sp_seed_instant_col;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order;
