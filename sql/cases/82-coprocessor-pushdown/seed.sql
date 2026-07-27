DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_pushdown $$
CREATE PROCEDURE sp_seed_pushdown()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 200000 DO
        INSERT INTO t_pushdown (user_id, name, age, city, bio, score, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('user_', i),
            18 + (i % 60),
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
            CASE WHEN i % 100 = 0 THEN CONCAT('bio_', i, ' keyword description text with details') ELSE NULL END,
            ROUND(10 + RAND() * 90, 2),
            DATE_SUB('2026-01-01', INTERVAL FLOOR(RAND() * 1095) DAY)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_pushdown();
DROP PROCEDURE IF EXISTS sp_seed_pushdown;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_pushdown_2 $$
CREATE PROCEDURE sp_seed_pushdown_2()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 50000 DO
        INSERT INTO t_pushdown_2 (name, value)
        VALUES (CONCAT('item_', i), FLOOR(1 + RAND() * 10000));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_pushdown_2();
DROP PROCEDURE IF EXISTS sp_seed_pushdown_2;

SELECT COUNT(*) AS pushdown_rows FROM t_pushdown;
SELECT COUNT(*) AS pushdown_2_rows FROM t_pushdown_2;
