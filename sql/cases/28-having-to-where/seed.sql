-- ============================================================
-- 造数据: 100 万订单数据
-- status 0-3 均匀分布，user_id 引用 1~50000
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_having $$
CREATE PROCEDURE sp_seed_order_having()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    WHILE i < 1000000 DO
        INSERT INTO t_order_having (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('NO', LPAD(i, 10, '0')),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
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

CALL sp_seed_order_having();
DROP PROCEDURE IF EXISTS sp_seed_order_having;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order_having;
