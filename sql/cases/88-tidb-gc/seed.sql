-- seed.sql: 插入 10 万行数据，status 在 0-9 之间均匀分布

DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS seed_gc_test()
BEGIN
    DECLARE i INT DEFAULT 1;
    WHILE i <= 100000 DO
        INSERT INTO t_gc_test (data, status)
        VALUES (CONCAT('record_', i), FLOOR(RAND() * 10));
        SET i = i + 1;
        -- 每 10000 行提交一次，避免单个事务过大
        IF i % 10000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;
    COMMIT;
END$$

DELIMITER ;

CALL seed_gc_test();

DROP PROCEDURE IF EXISTS seed_gc_test;
