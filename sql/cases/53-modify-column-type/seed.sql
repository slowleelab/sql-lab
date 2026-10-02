-- ============================================================
-- 造数据: 100 万行用户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_modify_col $$
CREATE PROCEDURE sp_seed_modify_col()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        INSERT INTO t_user (nickname, phone, email, age, status, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 7, '0')),
            CONCAT('1', FLOOR(3 + RAND() * 5), LPAD(FLOOR(RAND() * 1000000000), 9, '0')),
            CONCAT('user', i, '@example.com'),
            FLOOR(18 + RAND() * 60),
            IF(RAND() < 0.95, 1, 0),
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
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

CALL sp_seed_modify_col();
DROP PROCEDURE IF EXISTS sp_seed_modify_col;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_user;
