-- ============================================================
-- 案例六十七: RC vs RR 隔离级别锁行为差异
-- 场景: RR 下范围查询 FOR UPDATE 加 next-key lock 阻塞并发插入，
--       RC 下只加记录锁，并发插入不受影响
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
    KEY idx_user_status (user_id, status),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（隔离级别演示）';
