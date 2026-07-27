-- ============================================================
-- 造数据: 热表 5万行（近3个月）+ 冷表 15万行（3-12个月）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_hot_cold $$
CREATE PROCEDURE sp_seed_hot_cold()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 热表: 5 万行（近 3 个月，0-90 天）
    WHILE i < 50000 DO
        INSERT INTO t_order_hot (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                                     -- 10万用户
            CONCAT('NO', LPAD(i, 10, '0')),                                 -- 订单号
            ROUND(1 + RAND() * 9999, 2),                                    -- 金额
            FLOOR(RAND() * 4),                                              -- 状态
            NOW() - INTERVAL FLOOR(RAND() * 90) DAY                         -- 近3个月
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 冷表: 15 万行（3-12 个月，90-365 天）
    SET i = 0;
    WHILE i < 150000 DO
        INSERT INTO t_order_cold (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                                     -- 10万用户
            CONCAT('NO', LPAD(FLOOR(RAND() * 1000000), 10, '0')),           -- 订单号
            ROUND(1 + RAND() * 9999, 2),                                    -- 金额
            ELT(FLOOR(1 + RAND() * 2), 3, 3),                              -- 冷数据多为已完成(3)
            NOW() - INTERVAL (90 + FLOOR(RAND() * 275)) DAY                 -- 3-12个月
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 确保 user_id=12345 在两表都有数据，便于对比查询
    INSERT INTO t_order_hot (user_id, order_no, amount, status, created_at)
    VALUES (12345, 'NO_HOT_12345_01', 99.00, 1, NOW() - INTERVAL 10 DAY);
    INSERT INTO t_order_cold (user_id, order_no, amount, status, created_at)
    VALUES (12345, 'NO_COLD_12345_01', 199.00, 3, NOW() - INTERVAL 180 DAY);

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_hot_cold();
DROP PROCEDURE IF EXISTS sp_seed_hot_cold;

-- 确认数据量
SELECT 't_order_hot' AS tbl, COUNT(*) AS rows_count FROM t_order_hot
UNION ALL
SELECT 't_order_cold', COUNT(*) FROM t_order_cold;
