-- ============================================================
-- 案例四十七: 自连接查询优化
-- 场景: 员工表自连接查询员工及其直接上级姓名
-- ============================================================

DROP TABLE IF EXISTS t_employee;
CREATE TABLE t_employee (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    emp_name     VARCHAR(50)   NOT NULL              COMMENT '员工姓名',
    manager_id   BIGINT        NOT NULL DEFAULT 0    COMMENT '直属上级ID, 0表示无上级',
    department   VARCHAR(50)   NOT NULL              COMMENT '部门',
    salary       DECIMAL(10,2) NOT NULL              COMMENT '薪资',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_manager (manager_id),
    KEY idx_department (department)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='员工表';
