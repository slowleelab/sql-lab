-- ============================================================
-- 案例七十: 大批量 UPDATE 分批优化
-- 场景: 一次性 UPDATE 50 万行锁表太久，分批更新每次 1000 行
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
    KEY idx_status_created (status, created_at),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（分批更新演示）';
