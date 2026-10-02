DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_plan_cache $$
CREATE PROCEDURE sp_seed_plan_cache()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 100000 DO
        INSERT INTO t_plan_cache (user_id, name, city, score)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CONCAT('user_', i),
            CASE i % 10
                WHEN 0 THEN 'Beijing'
                WHEN 1 THEN 'Shanghai'
                WHEN 2 THEN 'Guangzhou'
                WHEN 3 THEN 'Shenzhen'
                WHEN 4 THEN 'Hangzhou'
                WHEN 5 THEN 'Chengdu'
                WHEN 6 THEN 'Wuhan'
                WHEN 7 THEN 'Nanjing'
                WHEN 8 THEN 'Xian'
                ELSE 'Chongqing'
            END,
            FLOOR(RAND() * 100)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_plan_cache();
DROP PROCEDURE IF EXISTS sp_seed_plan_cache;
SELECT COUNT(*) AS plan_cache_rows FROM t_plan_cache;
