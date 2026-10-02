-- ============================================================
-- 造数据: t_order_report 30万行（近365天）+ t_daily_summary 汇总填充
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_summary $$
CREATE PROCEDURE sp_seed_summary()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 明细表: 30 万行订单（近 365 天）
    WHILE i < 300000 DO
        INSERT INTO t_order_report (user_id, amount, status, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                                     -- 10万用户
            ROUND(1 + RAND() * 9999, 2),                                    -- 金额 1~10000
            FLOOR(RAND() * 4),                                              -- 状态 0~3
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY                        -- 近1年
                 - INTERVAL FLOOR(RAND() * 24) HOUR
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;
    COMMIT;

    -- 2. 汇总表: 从明细表聚合填充
    INSERT INTO t_daily_summary (stat_date, order_count, total_amount)
    SELECT DATE(created_at) AS d,
           COUNT(*) AS cnt,
           SUM(amount) AS total
    FROM t_order_report
    GROUP BY DATE(created_at);

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_summary();
DROP PROCEDURE IF EXISTS sp_seed_summary;

-- 确认数据量
SELECT 't_order_report' AS tbl, COUNT(*) AS rows_count FROM t_order_report
UNION ALL
SELECT 't_daily_summary', COUNT(*) FROM t_daily_summary;
