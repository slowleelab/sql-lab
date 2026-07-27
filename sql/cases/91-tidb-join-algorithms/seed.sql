DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_join_a $$
CREATE PROCEDURE sp_seed_t_join_a()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;
    WHILE i < 100000 DO
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
        INSERT INTO t_join_a (a_name, a_val)
        VALUES (
            CONCAT(v_name, '_', i),
            FLOOR(1 + RAND() * 10000)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_join_a();
DROP PROCEDURE IF EXISTS sp_seed_t_join_a;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_join_b $$
CREATE PROCEDURE sp_seed_t_join_b()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;
    WHILE i < 50000 DO
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
        INSERT INTO t_join_b (b_name, b_val)
        VALUES (
            CONCAT(v_name, '_', i),
            FLOOR(1 + RAND() * 50000)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_join_b();
DROP PROCEDURE IF EXISTS sp_seed_t_join_b;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_join_c $$
CREATE PROCEDURE sp_seed_t_join_c()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE v_name VARCHAR(50);
    SET autocommit = 0;
    WHILE i <= 500 DO
        SET v_name = CASE i % 10
            WHEN 0 THEN 'Alpha'
            WHEN 1 THEN 'Beta'
            WHEN 2 THEN 'Gamma'
            WHEN 3 THEN 'Delta'
            WHEN 4 THEN 'Epsilon'
            WHEN 5 THEN 'Zeta'
            WHEN 6 THEN 'Eta'
            WHEN 7 THEN 'Theta'
            WHEN 8 THEN 'Iota'
            ELSE 'Kappa'
        END;
        INSERT INTO t_join_c (c_name, c_val)
        VALUES (
            CONCAT(v_name, '_', i),
            i
        );
        SET i = i + 1;
        IF i % 100 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_join_c();
DROP PROCEDURE IF EXISTS sp_seed_t_join_c;

SELECT COUNT(*) AS t_join_a_rows FROM t_join_a;
SELECT COUNT(*) AS t_join_b_rows FROM t_join_b;
SELECT COUNT(*) AS t_join_c_rows FROM t_join_c;
