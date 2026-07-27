-- ============================================================
-- 造数据: 20 万行访问日志
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_access_log $$
CREATE PROCEDURE sp_seed_access_log()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_access_log (user_id, access_url, response_time, created_at)
        VALUES (
            FLOOR(1 + RAND() * 5000),                               -- 5000用户
            CONCAT('/api/', ELT(1 + FLOOR(RAND() * 5),
                'user','order','product','search','cart'), '/', FLOOR(RAND() * 1000)),
            FLOOR(10 + RAND() * 1990),                              -- 响应时间 10~2000ms
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

-- 确认数据量及活跃用户数
SELECT COUNT(*) AS total_rows FROM t_access_log;
SELECT COUNT(*) AS active_users FROM (
    SELECT user_id, COUNT(*) AS cnt FROM t_access_log GROUP BY user_id HAVING cnt > 100
) t;
