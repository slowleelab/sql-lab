-- 每表插入 1000 行基础数据用于演示

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_auto_inc $$
CREATE PROCEDURE sp_seed_auto_inc()
BEGIN
    DECLARE i INT DEFAULT 0;
    WHILE i < 1000 DO
        INSERT INTO t_auto_inc (name, val) VALUES (CONCAT('seed_', i), FLOOR(RAND() * 1000));
        SET i = i + 1;
    END WHILE;
END $$
DELIMITER ;
CALL sp_seed_auto_inc();
DROP PROCEDURE IF EXISTS sp_seed_auto_inc;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_auto_random $$
CREATE PROCEDURE sp_seed_auto_random()
BEGIN
    DECLARE i INT DEFAULT 0;
    WHILE i < 1000 DO
        INSERT INTO t_auto_random (name, val) VALUES (CONCAT('seed_', i), FLOOR(RAND() * 1000));
        SET i = i + 1;
    END WHILE;
END $$
DELIMITER ;
CALL sp_seed_auto_random();
DROP PROCEDURE IF EXISTS sp_seed_auto_random;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_shard_row $$
CREATE PROCEDURE sp_seed_shard_row()
BEGIN
    DECLARE i INT DEFAULT 0;
    WHILE i < 1000 DO
        INSERT INTO t_shard_row (name, val) VALUES (CONCAT('seed_', i), FLOOR(RAND() * 1000));
        SET i = i + 1;
    END WHILE;
END $$
DELIMITER ;
CALL sp_seed_shard_row();
DROP PROCEDURE IF EXISTS sp_seed_shard_row;

SELECT 't_auto_inc' AS tbl, COUNT(*) AS cnt FROM t_auto_inc
UNION ALL
SELECT 't_auto_random', COUNT(*) FROM t_auto_random
UNION ALL
SELECT 't_shard_row', COUNT(*) FROM t_shard_row;
