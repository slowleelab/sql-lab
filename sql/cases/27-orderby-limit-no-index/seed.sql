-- ============================================================
-- 造数据: 20 万条消息
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_message $$
CREATE PROCEDURE sp_seed_message()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_message (user_id, content, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('消息内容_', LPAD(i, 8, '0')),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                 - INTERVAL FLOOR(RAND() * 86400) SECOND
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

CALL sp_seed_message();
DROP PROCEDURE IF EXISTS sp_seed_message;

SELECT COUNT(*) AS total_rows, MIN(created_at) AS min_time, MAX(created_at) AS max_time FROM t_message;
