-- ============================================================
-- 案例四十四: NOT IN vs LEFT JOIN IS NULL
-- 场景: 查询没有下过订单的用户
--       用户表 t_user_check + 订单表 t_order_check (user_id 已建索引)
-- ============================================================

-- 用户表: 10 万用户
DROP TABLE IF EXISTS t_user_check;
CREATE TABLE t_user_check (
    id        BIGINT       NOT NULL AUTO_INCREMENT,
    username  VARCHAR(50)  NOT NULL              COMMENT '用户名',
    created_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表(NOT IN演示)';

-- 订单表: 20 万订单，约 80% 用户有订单
DROP TABLE IF EXISTS t_order_check;
CREATE TABLE t_order_check (
    id        BIGINT        NOT NULL AUTO_INCREMENT,
    user_id   BIGINT        NOT NULL              COMMENT '用户ID',
    amount    DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(NOT IN演示)';
