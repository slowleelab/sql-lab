-- ============================================================
-- 造数据: 20 万事件日志，少量 event_type 使每个类型匹配大量行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_event_log $$
CREATE PROCEDURE sp_seed_event_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_event_log (event_type, event_data, created_at)
        VALUES (
            ELT(FLOOR(1 + RAND() * 4), 'LOGIN', 'LOGOUT', 'VIEW', 'CLICK'),
            CONCAT('event_payload_', i, '_', FLOOR(RAND() * 10000)),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
                   - INTERVAL FLOOR(RAND() * 24) HOUR
                   - INTERVAL FLOOR(RAND() * 3600) SECOND
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

CALL sp_seed_event_log();
DROP PROCEDURE IF EXISTS sp_seed_event_log;

SELECT COUNT(*) AS total_rows FROM t_event_log;
