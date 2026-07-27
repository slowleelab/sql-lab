DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_lookup $$
CREATE PROCEDURE sp_seed_t_lookup()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_city VARCHAR(20);
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;
    WHILE i < 200000 DO
        SET v_city = CASE i % 10
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
        SET v_name = CASE i % 20
            WHEN 0 THEN 'Alice'
            WHEN 1 THEN 'Bob'
            WHEN 2 THEN 'Charlie'
            WHEN 3 THEN 'David'
            WHEN 4 THEN 'Eve'
            WHEN 5 THEN 'Frank'
            WHEN 6 THEN 'Grace'
            WHEN 7 THEN 'Hank'
            WHEN 8 THEN 'Ivy'
            WHEN 9 THEN 'Jack'
            WHEN 10 THEN 'Kate'
            WHEN 11 THEN 'Leo'
            WHEN 12 THEN 'Mia'
            WHEN 13 THEN 'Noah'
            WHEN 14 THEN 'Olivia'
            WHEN 15 THEN 'Paul'
            WHEN 16 THEN 'Quinn'
            WHEN 17 THEN 'Rose'
            WHEN 18 THEN 'Sam'
            ELSE 'Tina'
        END;
        INSERT INTO t_lookup (user_id, name, email, age, city, bio, score, created_at)
        VALUES (
            FLOOR(1 + RAND() * 200000),
            CONCAT(v_name, '_', i),
            CONCAT('user_', i, '@example.com'),
            18 + (i % 60),
            v_city,
            CONCAT('Bio for user ', i, ': ', CASE i % 3 WHEN 0 THEN 'Lorem ipsum dolor sit amet.' WHEN 1 THEN 'Consectetur adipiscing elit.' ELSE 'Sed do eiusmod tempor incididunt.' END),
            ROUND(1 + RAND() * 99, 2),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 1460) DAY)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_lookup();
DROP PROCEDURE IF EXISTS sp_seed_t_lookup;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_cluster $$
CREATE PROCEDURE sp_seed_t_cluster()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE v_city VARCHAR(20);
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;
    WHILE i <= 100000 DO
        SET v_city = CASE i % 10
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
        SET v_name = CASE i % 20
            WHEN 0 THEN 'Alice'
            WHEN 1 THEN 'Bob'
            WHEN 2 THEN 'Charlie'
            WHEN 3 THEN 'David'
            WHEN 4 THEN 'Eve'
            WHEN 5 THEN 'Frank'
            WHEN 6 THEN 'Grace'
            WHEN 7 THEN 'Hank'
            WHEN 8 THEN 'Ivy'
            WHEN 9 THEN 'Jack'
            WHEN 10 THEN 'Kate'
            WHEN 11 THEN 'Leo'
            WHEN 12 THEN 'Mia'
            WHEN 13 THEN 'Noah'
            WHEN 14 THEN 'Olivia'
            WHEN 15 THEN 'Paul'
            WHEN 16 THEN 'Quinn'
            WHEN 17 THEN 'Rose'
            WHEN 18 THEN 'Sam'
            ELSE 'Tina'
        END;
        INSERT INTO t_cluster_lookup (id, user_id, name, age, city)
        VALUES (
            i,
            FLOOR(1 + RAND() * 100000),
            CONCAT(v_name, '_', i),
            18 + (i % 60),
            v_city
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_cluster();
DROP PROCEDURE IF EXISTS sp_seed_t_cluster;

SELECT COUNT(*) AS t_lookup_rows FROM t_lookup;
SELECT COUNT(*) AS t_cluster_lookup_rows FROM t_cluster_lookup;
