-- ============================================================
-- 造数据: 100 万行订单数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order $$
CREATE PROCEDURE sp_seed_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 1000000 DO
        INSERT INTO t_order (user_id, order_no, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                              -- 10万用户
            CONCAT('NO', LPAD(i, 10, '0')),                           -- 订单号
            ROUND(1 + RAND() * 9999, 2),                              -- 金额 1~10000
            FLOOR(RAND() * 4),                                        -- 状态 0~3
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                  -- 近2年随机时间
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

CALL sp_seed_order();
DROP PROCEDURE IF EXISTS sp_seed_order;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order;
