-- ============================================================
-- 案例二十四: 冷热数据分离
-- 场景: 订单表按时间分离，热表（近3个月）+ 冷表（3个月以上）
-- ============================================================

-- 热表: 近 3 个月订单（5 万行）
DROP TABLE IF EXISTS t_order_hot;
CREATE TABLE t_order_hot (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单热表（近3个月）';

-- 冷表: 3 个月以上历史订单（15 万行，同结构）
DROP TABLE IF EXISTS t_order_cold;
CREATE TABLE t_order_cold (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单冷表（3个月以上历史）';
