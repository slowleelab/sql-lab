-- ============================================================
-- 案例六十八: 优化器 Hint 实战
-- 场景: 优化器误选 idx_status 导致 filesort，
--       通过 USE INDEX 强制使用 idx_user_created 避免 filesort
-- ============================================================

DROP TABLE IF EXISTS t_order;
CREATE TABLE t_order (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    order_no    VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id     BIGINT        NOT NULL              COMMENT '用户ID',
    amount      DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '订单金额',
    status      TINYINT       NOT NULL DEFAULT 0    COMMENT '状态: 0待付 1已付 2发货 3完成',
    created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（优化器Hint演示）';
