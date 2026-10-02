-- ============================================================
-- 造数据: 预填 20 条账户数据，id 1~20 连续，用于演示间隙锁
-- 同时制造间隙：删除 id=11~19，保留 id=10 和 id=20，形成 (10,20) 间隙
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_account $$
CREATE PROCEDURE sp_seed_account()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    -- 插入 20 条连续记录
    WHILE i < 20 DO
        INSERT INTO t_account (account_no, balance, created_at)
        VALUES (
            CONCAT('ACC', LPAD(i + 1, 4, '0')),                        -- ACC0001 ~ ACC0020
            ROUND(100 + RAND() * 9900, 2),                             -- 余额 100~10000
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

-- 制造间隙：删除 id 在 11~19 之间的记录，使 id=10 与 id=20 之间存在间隙
DELETE FROM t_account WHERE id BETWEEN 11 AND 19;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_account;
-- 确认数据：剩余 id 为 1~10 和 20
SELECT id, account_no, balance FROM t_account ORDER BY id;
