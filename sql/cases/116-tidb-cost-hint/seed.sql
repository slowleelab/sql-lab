-- ============================================================
-- 造数据: 20 万行，status 分布严重倾斜
--   status=0:  5%（约 1 万行）
--   status=1: 90%（约 18 万行）
--   status=2:  5%（约 1 万行）
-- city 均匀分布在 10 个城市
-- score 随机 0-100 分
-- user_id 唯一（1~200000）
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_hint_test $$
CREATE PROCEDURE sp_seed_hint_test()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 200000 DO
        INSERT INTO t_hint_test (user_id, status, city, score, created_at)
        VALUES (
            i + 1,
            CASE
                WHEN i % 20 < 1 THEN 0
                WHEN i % 20 < 19 THEN 1
                ELSE 2
            END,
            ELT(FLOOR(1 + RAND() * 10),
                'Beijing', 'Shanghai', 'Guangzhou', 'Shenzhen', 'Hangzhou',
                'Chengdu', 'Wuhan', 'Nanjing', 'Xian', 'Chongqing'),
            FLOOR(RAND() * 101),
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

CALL sp_seed_hint_test();
DROP PROCEDURE IF EXISTS sp_seed_hint_test;

-- 展示 status 分布倾斜情况
SELECT status, COUNT(*) AS cnt, ROUND(COUNT(*) * 100 / 200000, 2) AS pct
FROM t_hint_test GROUP BY status ORDER BY status;

-- 展示 city 分布情况
SELECT city, COUNT(*) AS cnt FROM t_hint_test GROUP BY city ORDER BY cnt DESC;

-- 展示 score 分布概况
SELECT MIN(score) AS min_score, MAX(score) AS max_score, AVG(score) AS avg_score
FROM t_hint_test;

SELECT COUNT(*) AS total_rows FROM t_hint_test;
