-- ============================================================
-- 造数据: 15 万访问日志，created_at 跨越约一年时间范围
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_access_log $$
CREATE PROCEDURE sp_seed_access_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 150000 DO
        INSERT INTO t_access_log (user_id, ip_addr, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CONCAT(FLOOR(RAND() * 223) + 1, '.', FLOOR(RAND() * 256), '.', FLOOR(RAND() * 256), '.', FLOOR(RAND() * 256)),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
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

CALL sp_seed_access_log();
DROP PROCEDURE IF EXISTS sp_seed_access_log;

SELECT COUNT(*) AS total_rows FROM t_access_log;
