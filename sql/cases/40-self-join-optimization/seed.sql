-- ============================================================
-- 造数据: 10 万员工，manager_id 指向其他员工 id
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_employee $$
CREATE PROCEDURE sp_seed_employee()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_dept VARCHAR(50);
    SET autocommit = 0;

    -- 1. 先插入前 100 名"管理层"员工（manager_id=0 无上级）
    WHILE i < 100 DO
        SET v_dept = ELT(1 + FLOOR(RAND() * 10),
            '技术部','产品部','市场部','财务部','人事部',
            '运营部','销售部','客服部','法务部','行政部');
        INSERT INTO t_employee (emp_name, manager_id, department, salary, created_at)
        VALUES (
            CONCAT('管理者_', LPAD(i, 4, '0')),
            0,
            v_dept,
            ROUND(20000 + RAND() * 80000, 2),
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
        );
        SET i = i + 1;
        IF i % 1000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;

    -- 2. 插入剩余员工，manager_id 指向已存在的员工 id
    WHILE i < 100000 DO
        SET v_dept = ELT(1 + FLOOR(RAND() * 10),
            '技术部','产品部','市场部','财务部','人事部',
            '运营部','销售部','客服部','法务部','行政部');
        INSERT INTO t_employee (emp_name, manager_id, department, salary, created_at)
        VALUES (
            CONCAT('员工_', LPAD(i, 6, '0')),
            FLOOR(1 + RAND() * i),                              -- 指向已存在的员工 id
            v_dept,
            ROUND(5000 + RAND() * 45000, 2),
            NOW() - INTERVAL FLOOR(RAND() * 1095) DAY
                 - INTERVAL FLOOR(RAND() * 24) HOUR
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

CALL sp_seed_employee();
DROP PROCEDURE IF EXISTS sp_seed_employee;

-- 确认数据量
SELECT COUNT(*) AS total_rows FROM t_employee;
SELECT COUNT(*) AS has_manager FROM t_employee WHERE manager_id > 0;
