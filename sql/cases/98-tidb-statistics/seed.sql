-- ============================================================
-- 造数据: 20 万行，status 分布不均匀（90% 为 1，10% 为 0）
-- city 均匀分布在 10 个城市，user_id 唯一（1~200000）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_stats $$
CREATE PROCEDURE sp_seed_stats()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_stats (user_id, status, city, amount, created_at)
        VALUES (
            i + 1,
            IF(i % 10 < 9, 1, 0),
            ELT(FLOOR(1 + RAND() * 10),
                'Beijing', 'Shanghai', 'Guangzhou', 'Shenzhen', 'Hangzhou',
                'Chengdu', 'Wuhan', 'Nanjing', 'Xian', 'Chongqing'),
            ROUND(10 + RAND() * 9990, 2),
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

CALL sp_seed_stats();
DROP PROCEDURE IF EXISTS sp_seed_stats;

-- 展示 status 分布倾斜情况
SELECT status, COUNT(*) AS cnt, ROUND(COUNT(*) * 100 / 200000, 2) AS pct
FROM t_stats GROUP BY status ORDER BY status;

-- 展示 city 分布情况
SELECT city, COUNT(*) AS cnt FROM t_stats GROUP BY city ORDER BY cnt DESC;

SELECT COUNT(*) AS total_rows FROM t_stats;
