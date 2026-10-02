-- ============================================================
-- 造数据: 20 万行，字段合理分布
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_ddl_test $$
CREATE PROCEDURE sp_seed_ddl_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 200000 DO
        INSERT INTO t_ddl_test (user_id, name, email, age, city)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('user_', i),
            CONCAT('user_', i, '@example.com'),
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
            END
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_ddl_test();
DROP PROCEDURE IF EXISTS sp_seed_ddl_test;

SELECT COUNT(*) AS total_rows FROM t_ddl_test;
