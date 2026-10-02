-- ============================================================
-- 案例六十九: 派生条件下推优化
-- 场景: 派生表 GROUP BY 在 5.7 中全量物化，外层 WHERE 无法下推；
--       8.0 优化器自动将条件下推到派生表内部，减少物化行数
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
    KEY idx_user_id (user_id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（派生条件下推演示）';
