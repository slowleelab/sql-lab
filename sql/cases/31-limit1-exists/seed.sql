-- ============================================================
-- 造数据: t_user_exists 10 万行 + t_order_exists 100 万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_exists $$
CREATE PROCEDURE sp_seed_exists()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 用户表: 10 万行
    WHILE i < 100000 DO
        INSERT INTO t_user_exists (username, phone, email, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('1', ELT(FLOOR(1 + RAND() * 7), '3','5','7','8','9','4','6'),
                   LPAD(FLOOR(RAND() * 100000000), 9, '0')),
            CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 100 万行，user_id 引用 1~100000，status 0-3 均匀分布
    SET i = 0;
    WHILE i < 1000000 DO
        INSERT INTO t_order_exists (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            CONCAT('NO', LPAD(i, 10, '0')),
            ROUND(1 + RAND() * 9999, 2),
            FLOOR(RAND() * 4),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_exists();
DROP PROCEDURE IF EXISTS sp_seed_exists;

-- 确认数据量
SELECT 't_user_exists' AS tbl, COUNT(*) AS rows_count FROM t_user_exists
UNION ALL
SELECT 't_order_exists', COUNT(*) FROM t_order_exists;
