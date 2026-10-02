-- ============================================================
-- 案例十三: 大 IN 列表优化
-- 场景: WHERE user_id IN (大列表) 性能差，改用临时表 JOIN
-- ============================================================

DROP TABLE IF EXISTS t_order_in;
CREATE TABLE t_order_in (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
