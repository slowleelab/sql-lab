-- ============================================================
-- 造数据: t_conn_test 10 万行
-- 重点不在数据量，在于连接诊断
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_conn_test $$
CREATE PROCEDURE sp_seed_conn_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 10 万行，user_id 在 1~10000 之间分布，data_value 为随机字符串
    WHILE i < 100000 DO
        INSERT INTO t_conn_test (user_id, data_value, created_at)
        VALUES (
            FLOOR(1 + RAND() * 10000),
            CONCAT('val_', LPAD(FLOOR(RAND() * 1000000), 7, '0')),
            NOW() - INTERVAL FLOOR(RAND() * 365) DAY
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_conn_test();
DROP PROCEDURE IF EXISTS sp_seed_conn_test;

-- 确认数据量
SELECT 't_conn_test' AS tbl, COUNT(*) AS rows_count FROM t_conn_test;
