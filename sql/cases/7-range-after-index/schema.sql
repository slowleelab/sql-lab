-- ============================================================
-- 案例七: 范围查询后列索引失效
-- 场景: 联合索引 (user_id, status, amount)，WHERE user_id=1 AND status>1 AND amount>500
--       status 是范围查询，其后的 amount 无法用到索引
-- ============================================================

DROP TABLE IF EXISTS t_order_range;
CREATE TABLE t_order_range (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_user_status_amount (user_id, status, amount)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
