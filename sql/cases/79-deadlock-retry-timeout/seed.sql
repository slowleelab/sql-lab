-- ============================================================
-- 造数据: 插入 5 万条计数器记录，counter_value 随机
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_counter $$
CREATE PROCEDURE sp_seed_counter()
BEGIN
    DECLARE i INT DEFAULT 0;

    SET autocommit = 0;

    WHILE i < 50000 DO
        INSERT INTO t_concurrent_counter (counter_value, thread_id, updated_at)
        VALUES (
            FLOOR(RAND() * 10000),                                  -- 计数值 0~9999
            CONCAT('T-', LPAD(FLOOR(RAND() * 100), 3, '0')),        -- 线程标识
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

CALL sp_seed_counter();
DROP PROCEDURE IF EXISTS sp_seed_counter;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_concurrent_counter;
-- 查看用于演示的计数器
SELECT id, counter_value, thread_id FROM t_concurrent_counter WHERE id = 1;
