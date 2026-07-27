DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_user $$
CREATE PROCEDURE sp_seed_user()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 100000 DO
        INSERT INTO t_user (name, age, city, salary)
        VALUES (CONCAT('user_', i), 18 + (i % 60), CASE i % 10 WHEN 0 THEN 'Beijing' WHEN 1 THEN 'Shanghai' WHEN 2 THEN 'Guangzhou' WHEN 3 THEN 'Shenzhen' WHEN 4 THEN 'Hangzhou' WHEN 5 THEN 'Chengdu' WHEN 6 THEN 'Wuhan' WHEN 7 THEN 'Nanjing' WHEN 8 THEN 'Xian' ELSE 'Chongqing' END, ROUND(3000 + RAND() * 27000, 2));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_user();
DROP PROCEDURE IF EXISTS sp_seed_user;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_order $$
CREATE PROCEDURE sp_seed_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 300000 DO
        INSERT INTO t_order (user_id, amount, status, created_at)
        VALUES (FLOOR(1 + RAND() * 100000), ROUND(10 + RAND() * 9990, 2), ELT(FLOOR(1 + RAND() * 4), 0, 1, 2, 3), DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_order();
DROP PROCEDURE IF EXISTS sp_seed_order;
SELECT COUNT(*) AS user_rows FROM t_user;
SELECT COUNT(*) AS order_rows FROM t_order;
