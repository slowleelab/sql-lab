-- ============================================================
-- 案例四十三: LEFT JOIN 改 INNER JOIN 释放优化器
-- 场景: 查询已支付订单及用户信息，LEFT JOIN 强制订单大表为驱动表
-- ============================================================

-- 用户表: 10 万用户
DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    nickname     VARCHAR(64)  NOT NULL              COMMENT '用户昵称',
    phone        VARCHAR(20)  NOT NULL DEFAULT ''   COMMENT '手机号',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '1正常/0禁用',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间',
    PRIMARY KEY (id),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 订单表: 100 万订单
DROP TABLE IF EXISTS t_order;
CREATE TABLE t_order (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成/4取消',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
