-- ============================================================
-- 造数据: t_small 1000行 + t_medium 5万行 + t_large 20万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_join_order $$
CREATE PROCEDURE sp_seed_join_order()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 1. 小表: 1000 行，val 取 1~10，便于用 val=1 过滤
    WHILE i < 1000 DO
        INSERT INTO t_small (val)
        VALUES (FLOOR(1 + RAND() * 10));
        SET i = i + 1;
        IF i % 1000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 中表: 5 万行，small_id 引用 1~1000
    SET i = 0;
    WHILE i < 50000 DO
        INSERT INTO t_medium (small_id, val)
        VALUES (FLOOR(1 + RAND() * 1000), FLOOR(RAND() * 1000));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 3. 大表: 20 万行，medium_id 引用 1~50000
    SET i = 0;
    WHILE i < 200000 DO
        INSERT INTO t_large (medium_id, val)
        VALUES (FLOOR(1 + RAND() * 50000), FLOOR(RAND() * 10000));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_join_order();
DROP PROCEDURE IF EXISTS sp_seed_join_order;

SELECT 't_small' AS tbl, COUNT(*) AS rows_count FROM t_small
UNION ALL
SELECT 't_medium', COUNT(*) FROM t_medium
UNION ALL
SELECT 't_large', COUNT(*) FROM t_large;
