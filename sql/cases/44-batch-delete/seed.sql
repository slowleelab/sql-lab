-- ============================================================
-- 造数据: 20 万行日志，其中 level=0 (DEBUG) 占大部分
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_log $$
CREATE PROCEDURE sp_seed_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_level TINYINT;
    SET autocommit = 0;

    WHILE i < 200000 DO
        -- 70% DEBUG(0), 15% INFO(1), 10% WARN(2), 5% ERROR(3)
        IF RAND() < 0.70 THEN
            SET v_level = 0;
        ELSEIF RAND() < 0.50 THEN
            SET v_level = 1;
        ELSEIF RAND() < 0.67 THEN
            SET v_level = 2;
        ELSE
            SET v_level = 3;
        END IF;

        INSERT INTO t_log (level, message, created_at)
        VALUES (
            v_level,
            CONCAT('log-', LPAD(i, 7, '0'), '-', SUBSTRING(MD5(RAND()), 1, 16)),
            NOW() - INTERVAL FLOOR(RAND() * 90) DAY
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

CALL sp_seed_log();
DROP PROCEDURE IF EXISTS sp_seed_log;

-- 确认数据量及各级别分布
SELECT COUNT(*) AS total_rows FROM t_log;
SELECT level, COUNT(*) AS cnt FROM t_log GROUP BY level ORDER BY level;
