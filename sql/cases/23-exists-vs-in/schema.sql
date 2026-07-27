-- ============================================================
-- 案例十四: EXISTS vs IN 选择
-- 场景: 大表(员工30万) 查询属于"技术%"部门的人员
-- ============================================================

-- 部门表(小): 100 行
DROP TABLE IF EXISTS t_dept;
CREATE TABLE t_dept (
    id     BIGINT      NOT NULL AUTO_INCREMENT,
    name   VARCHAR(50) NOT NULL              COMMENT '部门名',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='部门表';

-- 员工表(大): 30 万行
DROP TABLE IF EXISTS t_emp;
CREATE TABLE t_emp (
    id       BIGINT        NOT NULL AUTO_INCREMENT,
    dept_id  BIGINT        NOT NULL              COMMENT '部门ID',
    name     VARCHAR(50)   NOT NULL              COMMENT '员工名',
    salary   DECIMAL(10,2) NOT NULL              COMMENT '薪资',
    PRIMARY KEY (id),
    KEY idx_dept_id (dept_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='员工表';
