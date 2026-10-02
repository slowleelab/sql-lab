-- ============================================================
-- 造数据: 12 个月日志数据，每月约 8 万行，共约 96 万行
-- (1000万行造数据过慢，96万行足以展示分区裁剪效果)
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_partition_log $$
CREATE PROCEDURE sp_seed_partition_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_month INT DEFAULT 1;
    SET autocommit = 0;

    -- 12 个月，每月约 8 万行
    WHILE i < 960000 DO
        SET v_month = 1 + FLOOR(i / 80000);  -- 1~12 月

        INSERT INTO t_partition_log (user_id, log_level, message, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),                               -- 1万用户
            FLOOR(RAND() * 4),                                       -- 级别 0~3
            CONCAT('log-', LPAD(i, 7, '0'), '-', SUBSTRING(MD5(RAND()), 1, 16)),
            CONCAT('2024-', LPAD(v_month, 2, '0'), '-',
                   LPAD(1 + FLOOR(RAND() * 28), 2, '0'), ' ',
                   LPAD(FLOOR(RAND() * 24), 2, '0'), ':',
                   LPAD(FLOOR(RAND() * 60), 2, '0'), ':',
                   LPAD(FLOOR(RAND() * 60), 2, '0'))
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

CALL sp_seed_partition_log();
DROP PROCEDURE IF EXISTS sp_seed_partition_log;

-- 确认数据量及各月分布
SELECT COUNT(*) AS total_rows FROM t_partition_log;
SELECT MONTH(created_at) AS log_month, COUNT(*) AS cnt
FROM t_partition_log
GROUP BY MONTH(created_at)
ORDER BY log_month;
