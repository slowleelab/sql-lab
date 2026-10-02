-- ============================================================
-- 造数据: 10 万员工，100 个部门，每部门约 1000 人
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_salary $$
CREATE PROCEDURE sp_seed_salary()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_salary (emp_name, dept, salary)
        VALUES (
            CONCAT('员工-', LPAD(i, 6, '0')),
            CONCAT('dept-', LPAD(FLOOR(1 + RAND() * 100), 3, '0')),
            ROUND(5000 + RAND() * 45000, 2)
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

CALL sp_seed_salary();
DROP PROCEDURE IF EXISTS sp_seed_salary;

-- 查看部门数和每部门人数
SELECT COUNT(DISTINCT dept) AS dept_count,
       ROUND(COUNT(*) / COUNT(DISTINCT dept)) AS avg_emp_per_dept
FROM t_salary;

SELECT COUNT(*) AS total_rows FROM t_salary;
