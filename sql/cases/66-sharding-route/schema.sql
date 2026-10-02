-- ============================================================
-- 案例四十六: 分库分表路由策略
-- 场景: 订单表按 user_id % 4 拆分为 4 个分片，用 4 张表模拟
-- ============================================================

-- 分片 0: user_id % 4 = 0
DROP TABLE IF EXISTS t_order_0;
CREATE TABLE t_order_0 (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单分片0';

-- 分片 1: user_id % 4 = 1
DROP TABLE IF EXISTS t_order_1;
CREATE TABLE t_order_1 (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单分片1';

-- 分片 2: user_id % 4 = 2
DROP TABLE IF EXISTS t_order_2;
CREATE TABLE t_order_2 (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单分片2';

-- 分片 3: user_id % 4 = 3
DROP TABLE IF EXISTS t_order_3;
CREATE TABLE t_order_3 (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单分片3';
