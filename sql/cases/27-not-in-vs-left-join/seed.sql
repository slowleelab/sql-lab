-- ============================================================
-- 造数据: 10 万用户 + 20 万订单（约 8 万用户有订单，2 万无订单）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_not_in $$
CREATE PROCEDURE sp_seed_not_in()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 用户表: 10 万用户
    WHILE i < 100000 DO
        INSERT INTO t_user_check (username, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 20 万订单，user_id 取 1~80000（让 80001~100000 无订单）
    SET i = 0;
    WHILE i < 200000 DO
        INSERT INTO t_order_check (user_id, amount, created_at)
        VALUES (
            FLOOR(1 + RAND() * 80000),
            ROUND(1 + RAND() * 9999, 2),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_not_in();
DROP PROCEDURE IF EXISTS sp_seed_not_in;

SELECT 't_user_check' AS tbl, COUNT(*) AS rows_count FROM t_user_check
UNION ALL
SELECT 't_order_check', COUNT(*) FROM t_order_check;
