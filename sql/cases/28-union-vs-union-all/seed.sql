-- ============================================================
-- 造数据: t_source_a 10 万行（code 以 A 开头）, t_source_b 10 万行（code 以 B 开头）
-- 两表 code 前缀不同，天然无重复
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_union $$
CREATE PROCEDURE sp_seed_union()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    -- 数据源 A: code 形如 A00001
    WHILE i < 100000 DO
        INSERT INTO t_source_a (code, name)
        VALUES (CONCAT('A', LPAD(i, 6, '0')), CONCAT('名称A_', i));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 数据源 B: code 形如 B00001（与 A 不重复）
    SET i = 0;
    WHILE i < 100000 DO
        INSERT INTO t_source_b (code, name)
        VALUES (CONCAT('B', LPAD(i, 6, '0')), CONCAT('名称B_', i));
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_union();
DROP PROCEDURE IF EXISTS sp_seed_union;

SELECT 't_source_a' AS tbl, COUNT(*) AS rows_count FROM t_source_a
UNION ALL
SELECT 't_source_b', COUNT(*) FROM t_source_b;
