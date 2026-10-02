-- ============================================================
-- 案例四十四: 大表加列默认值 INSTANT 秒级完成
-- 场景: 50 万行订单表（模拟生产 500 万行）加 source 列
-- ============================================================

DROP TABLE IF EXISTS t_order;
CREATE TABLE t_order (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '下单用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_id (user_id),
    KEY idx_status_created (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（演示加列）';
