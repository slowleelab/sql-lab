-- ============================================================
-- 造数据: 20 万访问日志，user_id 约 2 万个不同用户
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_visit_log $$
CREATE PROCEDURE sp_seed_visit_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_visit_log (user_id, page_url, visit_time)
        VALUES (
            FLOOR(1 + RAND() * 20000),
            CONCAT('/page/', FLOOR(1 + RAND() * 100)),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
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

CALL sp_seed_visit_log();
DROP PROCEDURE IF EXISTS sp_seed_visit_log;

SELECT COUNT(*) AS total_rows, COUNT(DISTINCT user_id) AS distinct_users FROM t_visit_log;
