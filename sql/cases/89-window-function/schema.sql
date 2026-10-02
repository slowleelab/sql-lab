-- ============================================================
-- 案例三十七: 窗口函数替代相关子查询
-- 场景: 查每个部门薪资最高的员工
--   传统方案: 相关子查询 WHERE salary = (SELECT MAX(salary) ... WHERE dept = s.dept)
--   8.0 方案: ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC)
-- ============================================================

DROP TABLE IF EXISTS t_salary;
CREATE TABLE t_salary (
    id        BIGINT        NOT NULL AUTO_INCREMENT,
    emp_name  VARCHAR(50)   NOT NULL                COMMENT '员工姓名',
    dept      VARCHAR(20)   NOT NULL                COMMENT '部门',
    salary    DECIMAL(10,2) NOT NULL                COMMENT '薪资',
    PRIMARY KEY (id),
    KEY idx_dept_salary (dept, salary)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='薪资表（窗口函数演示）';
