-- ============================================================
-- 造数据: t_a 5万行 + t_b 10万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_hash_join $$
CREATE PROCEDURE sp_seed_hash_join()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. t_a: 5 万行
    WHILE i < 50000 DO
        INSERT INTO t_a (val, name)
        VALUES (
            FLOOR(RAND() * 50000),
            CONCAT('name_', LPAD(i, 6, '0'))
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. t_b: 10 万行，a_id 引用 t_a.id (1~50000)
    SET i = 0;
    WHILE i < 100000 DO
        INSERT INTO t_b (a_id, data)
        VALUES (
            FLOOR(1 + RAND() * 50000),
            CONCAT('data_', LPAD(i, 6, '0'))
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_hash_join();
DROP PROCEDURE IF EXISTS sp_seed_hash_join;

SELECT 't_a' AS tbl, COUNT(*) AS rows_count FROM t_a
UNION ALL
SELECT 't_b', COUNT(*) FROM t_b;
