-- ============================================================
-- 造数据: 30 万行，group_id 1-50000 均匀分布
-- data 为短文本随机填充，value 为 1-10000 随机整数
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_oom $$
CREATE PROCEDURE sp_seed_oom()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 300000 DO
        INSERT INTO t_oom_test (group_id, data, value, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('record_', LPAD(FLOOR(RAND() * 999999), 6, '0')),
            FLOOR(1 + RAND() * 10000),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY)
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

CALL sp_seed_oom();
DROP PROCEDURE IF EXISTS sp_seed_oom;

-- 展示 group_id 分布情况（前 10 个 group）
SELECT group_id, COUNT(*) AS cnt
FROM t_oom_test
GROUP BY group_id
ORDER BY cnt DESC
LIMIT 10;

-- 总行数确认
SELECT COUNT(*) AS total_rows FROM t_oom_test;
