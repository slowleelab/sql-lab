-- ============================================================
-- 造数据: 预填充少量数据(1万行)用于 EXPLAIN 验证表结构
-- 主测试数据由 bad.sql / good.sql 演示插入过程
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_batch $$
CREATE PROCEDURE sp_seed_batch()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 10000 DO
        INSERT INTO t_batch_data (user_name, email, amount, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
            ROUND(1 + RAND() * 9999, 2),
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

CALL sp_seed_batch();
DROP PROCEDURE IF EXISTS sp_seed_batch;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_batch_data;
