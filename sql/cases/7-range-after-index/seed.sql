-- ============================================================
-- 造数据: 30 万行订单数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order_range $$
CREATE PROCEDURE sp_seed_order_range()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 300000 DO
        INSERT INTO t_order_range (user_id, status, amount, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                              -- 10万用户
            FLOOR(RAND() * 4),                                        -- 状态 0~3
            ROUND(1 + RAND() * 9999, 2),                              -- 金额 1~10000
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

CALL sp_seed_order_range();
DROP PROCEDURE IF EXISTS sp_seed_order_range;

-- 插入固定 user_id 的数据，便于 bad/good 对比测试
INSERT INTO t_order_range (user_id, status, amount, created_at)
VALUES
    (1000, 2, 600.00, '2026-01-15 10:00:00'),
    (1000, 2, 800.00, '2026-02-20 14:30:00'),
    (1000, 3, 1200.00,'2026-03-10 09:15:00'),
    (1000, 1, 300.00, '2026-04-05 16:45:00');

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_order_range;
