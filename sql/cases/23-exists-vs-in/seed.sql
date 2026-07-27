-- ============================================================
-- 造数据: t_dept 100行 + t_emp 30万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_exists_in $$
CREATE PROCEDURE sp_seed_exists_in()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_dept_name VARCHAR(50);
    SET autocommit = 0;

    -- 1. 部门表: 100 行，其中部分部门以"技术"开头
    WHILE i < 100 DO
        SET v_dept_name = CASE
            WHEN i < 5  THEN CONCAT('技术', ELT((i MOD 3) + 1, '部','中心','研发'))
            WHEN i < 10 THEN CONCAT('市场', ELT((i MOD 2) + 1, '部','中心'))
            WHEN i < 15 THEN CONCAT('财务', ELT((i MOD 2) + 1, '部','中心'))
            ELSE CONCAT('部门_', LPAD(i, 3, '0'))
        END;
        INSERT INTO t_dept (name) VALUES (v_dept_name);
        SET i = i + 1;
        IF i % 100 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 员工表: 30 万行，dept_id 引用 1~100
    SET i = 0;
    WHILE i < 300000 DO
        INSERT INTO t_emp (dept_id, name, salary)
        VALUES (
            FLOOR(1 + RAND() * 100),
            CONCAT('员工_', LPAD(i, 6, '0')),
            ROUND(3000 + RAND() * 47000, 2)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_exists_in();
DROP PROCEDURE IF EXISTS sp_seed_exists_in;

SELECT 't_dept' AS tbl, COUNT(*) AS rows_count FROM t_dept
UNION ALL
SELECT 't_emp', COUNT(*) FROM t_emp;
