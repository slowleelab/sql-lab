-- ============================================================
-- 案例二: 联合索引最左前缀失效
-- 场景: 订单表有联合索引 (user_id, status, created_at)，
--       查询跳过 user_id 只用 status / created_at，索引失效
-- ============================================================

DROP TABLE IF EXISTS t_order_latest;
CREATE TABLE t_order_latest (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_user_status_created (user_id, status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
