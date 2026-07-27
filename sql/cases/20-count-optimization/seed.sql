-- ============================================================
-- 造数据: t_order_count 50万行 + 填充汇总表 t_order_daily_stats
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_count $$
CREATE PROCEDURE sp_seed_count()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 订单表: 50 万行
    WHILE i < 500000 DO
        INSERT INTO t_order_count (user_id, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            FLOOR(RAND() * 4),
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 填充汇总表: 按天统计订单数（近 730 天）
    INSERT INTO t_order_daily_stats (stat_date, order_count)
    SELECT DATE(created_at) AS stat_date, COUNT(*) AS order_count
    FROM t_order_count
    GROUP BY DATE(created_at);
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_count();
DROP PROCEDURE IF EXISTS sp_seed_count;

-- 确认数据量
SELECT 't_order_count' AS tbl, COUNT(*) AS rows_count FROM t_order_count
UNION ALL
SELECT 't_order_daily_stats', COUNT(*) FROM t_order_daily_stats;
