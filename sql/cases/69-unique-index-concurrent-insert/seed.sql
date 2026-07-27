-- ============================================================
-- 造数据: 预填 10 万条唯一编码记录，uk_code 格式 CODE00001 ~ CODE100000
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_unique_test $$
CREATE PROCEDURE sp_seed_unique_test()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_unique_test (uk_code, counter, updated_at)
        VALUES (
            CONCAT('CODE', LPAD(i + 1, 5, '0')),                       -- CODE00001 ~ CODE100000
            FLOOR(RAND() * 1000),                                      -- 计数 0~999
            NOW() - INTERVAL FLOOR(RAND() * 30) DAY
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

CALL sp_seed_unique_test();
DROP PROCEDURE IF EXISTS sp_seed_unique_test;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_unique_test;
-- 查看 CODE00001 的记录（用于 bad/good 对比）
SELECT id, uk_code, counter FROM t_unique_test WHERE uk_code = 'CODE00001';
