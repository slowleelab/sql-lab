DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_diag $$
CREATE PROCEDURE sp_seed_diag()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_user_id BIGINT;
    DECLARE v_name VARCHAR(50);
    DECLARE v_age INT;
    DECLARE v_city VARCHAR(20);
    DECLARE v_score INT;
    DECLARE v_created_at DATETIME;
    DECLARE v_base_date DATETIME DEFAULT '2024-01-01 00:00:00';
    SET autocommit = 0;
    WHILE i < 200000 DO
        -- 模拟真实数据分布：user_id 集中在 1-50000，少数用户数据量极大（热点用户）
        IF i % 1000 < 900 THEN
            SET v_user_id = FLOOR(1 + RAND() * 50000);
        ELSE
            -- 10% 的数据集中在 top 100 用户（模拟热点用户行为）
            SET v_user_id = FLOOR(1 + RAND() * 100);
        END IF;

        SET v_name = CONCAT('user_', v_user_id, '_', i);

        -- 年龄分布：正态分布模拟，集中在 20-40 岁
        SET v_age = FLOOR(20 + RAND() * 40);

        -- 城市分布不均：北京/上海/深圳占 60%，其他城市占 40%
        SET v_city = CASE FLOOR(RAND() * 100)
            WHEN 0 THEN 'Beijing'
            WHEN 1 THEN 'Beijing'
            WHEN 2 THEN 'Beijing'
            WHEN 3 THEN 'Beijing'
            WHEN 4 THEN 'Beijing'
            WHEN 5 THEN 'Shanghai'
            WHEN 6 THEN 'Shanghai'
            WHEN 7 THEN 'Shanghai'
            WHEN 8 THEN 'Shanghai'
            WHEN 9 THEN 'Shanghai'
            WHEN 10 THEN 'Shenzhen'
            WHEN 11 THEN 'Shenzhen'
            WHEN 12 THEN 'Shenzhen'
            WHEN 13 THEN 'Shenzhen'
            WHEN 14 THEN 'Shenzhen'
            WHEN 15 THEN 'Guangzhou'
            WHEN 16 THEN 'Hangzhou'
            WHEN 17 THEN 'Chengdu'
            WHEN 18 THEN 'Wuhan'
            WHEN 19 THEN 'Nanjing'
            WHEN 20 THEN 'Xian'
            WHEN 21 THEN 'Chongqing'
            WHEN 22 THEN 'Tianjin'
            WHEN 23 THEN 'Suzhou'
            WHEN 24 THEN 'Changsha'
            ELSE 'Other'
        END;

        SET v_score = FLOOR(RAND() * 100);

        -- 时间分布集中在最近 30 天，少量历史数据
        IF i % 100 < 70 THEN
            SET v_created_at = DATE_ADD(v_base_date, INTERVAL FLOOR(RAND() * 30) DAY);
        ELSE
            SET v_created_at = DATE_ADD(v_base_date, INTERVAL FLOOR(RAND() * 365) DAY);
        END IF;
        SET v_created_at = DATE_ADD(v_created_at, INTERVAL FLOOR(RAND() * 86400) SECOND);

        INSERT INTO t_diag (user_id, name, age, city, score, created_at)
        VALUES (v_user_id, v_name, v_age, v_city, v_score, v_created_at);

        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_diag();
DROP PROCEDURE IF EXISTS sp_seed_diag;

-- 验证数据量
SELECT COUNT(*) AS diag_rows FROM t_diag;

-- 查看数据分布（城市分布）
SELECT city, COUNT(*) AS cnt FROM t_diag GROUP BY city ORDER BY cnt DESC LIMIT 10;

-- 查看热点用户（top user_id 行数最多的用户）
SELECT user_id, COUNT(*) AS cnt FROM t_diag GROUP BY user_id ORDER BY cnt DESC LIMIT 10;
