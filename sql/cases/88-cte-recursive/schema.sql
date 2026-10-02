-- ============================================================
-- 案例三十六: CTE 递归查询优化树形结构
-- 场景: 组织架构树，manager_id 指向 id 形成层级，查某经理下所有层级下属
-- 传统多次自连接写死层数，8.0 递归 CTE 一条语句遍历任意深度
-- ============================================================

DROP TABLE IF EXISTS t_employee_org;
CREATE TABLE t_employee_org (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    emp_name    VARCHAR(50)  NOT NULL                COMMENT '员工姓名',
    manager_id  BIGINT       NULL DEFAULT NULL       COMMENT '直属上级ID，NULL表示顶层',
    level       INT          NOT NULL DEFAULT 1      COMMENT '层级(1=顶层)',
    PRIMARY KEY (id),
    KEY idx_manager (manager_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='员工组织架构表（CTE递归演示）';
