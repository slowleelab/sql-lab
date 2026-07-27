-- ============================================================
-- 造数据: 10 万行账户数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_account $$
CREATE PROCEDURE sp_seed_account()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_account (account_no, user_name, balance, status, created_at)
        VALUES (
            CONCAT('ACC', LPAD(i + 1, 8, '0')),                        -- ACC00000001 ~ ACC00100000
            CONCAT('user_', FLOOR(1 + RAND() * 50000)),                 -- 随机用户名
            ROUND(100 + RAND() * 99900, 2),                             -- 余额 100~100000
            1,                                                          -- 状态正常
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

CALL sp_seed_account();
DROP PROCEDURE IF EXISTS sp_seed_account;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_account;
-- 查看用于演示的账户
SELECT id, account_no, user_name, balance FROM t_account WHERE id = 1;
