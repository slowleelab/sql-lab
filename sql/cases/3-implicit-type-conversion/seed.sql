-- ============================================================
-- 造数据: 50 万用户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user $$
CREATE PROCEDURE sp_seed_user()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 500000 DO
        INSERT IGNORE INTO t_user (username, phone, email, status, created_at)
        VALUES (
            CONCAT('user_', i),
            CONCAT('1', ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0')),
            CONCAT('user_', i, '@example.com'),
            IF(RAND() > 0.05, 1, 0),
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
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

CALL sp_seed_user();
DROP PROCEDURE IF EXISTS sp_seed_user;

-- 插入一条固定手机号，用于 bad/good 对比测试
INSERT IGNORE INTO t_user (username, phone, email, status, created_at)
VALUES ('test_user', '13800138000', 'test@example.com', 1, NOW());

SELECT COUNT(*) AS total_rows FROM t_user;
