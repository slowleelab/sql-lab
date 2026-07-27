-- ============================================================
-- 造数据: 50 万用户数据
-- gender 2 个值 (M/F)，created_at 随机分布在近 2 年
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user_skip $$
CREATE PROCEDURE sp_seed_user_skip()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_gender CHAR(1);

    SET autocommit = 0;

    WHILE i < 500000 DO
        SET v_gender = IF(RAND() > 0.5, 'M', 'F');

        INSERT INTO t_user_skip (username, gender, created_at, email, phone)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            v_gender,
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY - INTERVAL FLOOR(RAND() * 86400) SECOND,
            CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
            CONCAT('1', ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0'))
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

CALL sp_seed_user_skip();
DROP PROCEDURE IF EXISTS sp_seed_user_skip;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_user_skip;
