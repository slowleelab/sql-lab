-- ============================================================
-- 造数据: 30 万行，status 分布严重不均
--   status=0:  5% (15000 行)  — 待处理
--   status=1: 90% (270000 行) — 已完成（占绝大多数）
--   status=2:  5% (15000 行)  — 已取消
-- city: 10 个城市均匀分布
-- created_at: 过去 1 年内随机
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_spm_test $$
CREATE PROCEDURE sp_seed_spm_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_status TINYINT;
    DECLARE v_city VARCHAR(20);
    DECLARE v_created DATETIME;
    DECLARE r DOUBLE;
    DECLARE total_rows INT DEFAULT 300000;

    SET autocommit = 0;

    WHILE i < total_rows DO
        -- 按概率分配 status: 0(5%), 1(90%), 2(5%)
        SET r = RAND();
        IF r < 0.05 THEN
            SET v_status = 0;
        ELSEIF r < 0.95 THEN
            SET v_status = 1;
        ELSE
            SET v_status = 2;
        END IF;

        -- 10 个城市均匀分布
        SET v_city = CASE (i % 10)
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
        END;

        -- 过去 1 年内随机时间
        SET v_created = NOW() - INTERVAL FLOOR(RAND() * 365) DAY
                        - INTERVAL FLOOR(RAND() * 86400) SECOND;

        INSERT INTO t_spm_test (user_id, status, city, amount, created_at)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            v_status,
            v_city,
            ROUND(RAND() * 9999.99, 2),
            v_created
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

CALL sp_seed_spm_test();
DROP PROCEDURE IF EXISTS sp_seed_spm_test;

-- 验证数据分布
SELECT status,
       COUNT(*) AS cnt,
       CONCAT(ROUND(COUNT(*) / 300000 * 100, 2), '%') AS pct
FROM t_spm_test
GROUP BY status
ORDER BY status;

SELECT COUNT(*) AS total_rows FROM t_spm_test;
