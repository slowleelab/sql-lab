-- ============================================================
-- 案例十: 子查询改写为 JOIN
-- 场景: 查询"有订单的用户"，用 IN 子查询 vs INNER JOIN
-- ============================================================

-- 用户表: 5 万行
DROP TABLE IF EXISTS t_user_sub;
CREATE TABLE t_user_sub (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 订单表: 20 万行
DROP TABLE IF EXISTS t_order_sub;
CREATE TABLE t_order_sub (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
