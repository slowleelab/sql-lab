DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_follower $$
CREATE PROCEDURE sp_seed_follower()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;
    WHILE i < 200000 DO
        INSERT INTO t_follower (user_id, name, score, city)
        VALUES (
            FLOOR(1 + RAND() * 100000),
            CONCAT('user_', i),
            ROUND(RAND() * 100, 2),
            CASE i % 10
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
            END
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_follower();
DROP PROCEDURE IF EXISTS sp_seed_follower;

-- 验证数据分布：10 个城市各约 20000 行
SELECT city, COUNT(*) AS cnt FROM t_follower GROUP BY city ORDER BY cnt DESC;
SELECT COUNT(*) AS total_rows FROM t_follower;
