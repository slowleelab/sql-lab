-- ============================================================
-- 造数据: t_user_sub 5万行 + t_order_sub 20万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_sub_join $$
CREATE PROCEDURE sp_seed_sub_join()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 用户表: 5 万行
    WHILE i < 50000 DO
        INSERT INTO t_user_sub (username, phone, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('1', LPAD(i, 10, '0')),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 订单表: 20 万行，user_id 引用 1~50000
    SET i = 0;
    WHILE i < 200000 DO
        INSERT INTO t_order_sub (user_id, order_no, amount, created_at)
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

CALL sp_seed_sub_join();
DROP PROCEDURE IF EXISTS sp_seed_sub_join;

-- 确认数据量
SELECT 't_user_sub' AS tbl, COUNT(*) AS rows_count FROM t_user_sub
UNION ALL
SELECT 't_order_sub', COUNT(*) FROM t_order_sub;
