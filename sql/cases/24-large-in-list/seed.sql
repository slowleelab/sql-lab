-- ============================================================
-- 造数据: t_order_in 20万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_in_list $$
CREATE PROCEDURE sp_seed_in_list()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_order_in (user_id, order_no, amount, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('NO', LPAD(i, 10, '0')),
            ROUND(1 + RAND() * 9999, 2),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_in_list();
DROP PROCEDURE IF EXISTS sp_seed_in_list;

SELECT COUNT(*) AS total_rows FROM t_order_in;
