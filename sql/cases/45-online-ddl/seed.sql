-- ============================================================
-- 造数据: 20 万行大表数据
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_big_table $$
CREATE PROCEDURE sp_seed_big_table()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_big_table (user_id, content, created_at)
        VALUES (
            FLOOR(1 + RAND() * 100000),                               -- 10万用户
            REPEAT('x', FLOOR(1 + RAND() * 200)),                     -- 随机长度内容
            NOW() - INTERVAL FLOOR(RAND() * 730) DAY                  -- 近2年随机时间
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

CALL sp_seed_big_table();
DROP PROCEDURE IF EXISTS sp_seed_big_table;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_big_table;
