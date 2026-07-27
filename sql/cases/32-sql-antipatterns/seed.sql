-- ============================================================
-- 造数据: 30 万行订单数据
-- user_id 1~10000 随机，status 0~3 随机，remark 约 20% 为 NULL（演示 COUNT(col) 陷阱）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_anti_test $$
CREATE PROCEDURE sp_seed_anti_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 300000 DO
        INSERT INTO t_anti_test (user_id, order_no, amount, status, remark, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CONCAT('ORD', LPAD(i, 8, '0')),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
            IF(RAND() > 0.2, CONCAT('备注_', FLOOR(RAND() * 100000)), NULL),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
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

CALL sp_seed_anti_test();
DROP PROCEDURE IF EXISTS sp_seed_anti_test;

SELECT COUNT(*) AS total_rows FROM t_anti_test;
