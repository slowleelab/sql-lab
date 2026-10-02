-- ============================================================
-- 案例四十八: JOIN + GROUP BY 聚合优化
-- 场景: 订单表 JOIN 用户表后按地区统计订单数和总金额
-- ============================================================

-- 订单表: 100 万行
DROP TABLE IF EXISTS t_order;
CREATE TABLE t_order (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    KEY idx_status_created (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';

-- 用户表: 1 万行
DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_name    VARCHAR(50)   NOT NULL              COMMENT '用户名',
    region       VARCHAR(20)   NOT NULL              COMMENT '地区',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间',
    PRIMARY KEY (id),
    KEY idx_region (region)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
