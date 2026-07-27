-- ============================================================
-- 案例二十六: 死锁排查与分析
-- 场景: 两个事务反向更新同一批订单，加锁顺序不一致导致死锁
-- ============================================================

DROP TABLE IF EXISTS t_order_deadlock;
CREATE TABLE t_order_deadlock (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    order_no    VARCHAR(32)   NOT NULL                COMMENT '订单号',
    amount      DECIMAL(10,2) NOT NULL DEFAULT 0.00   COMMENT '订单金额',
    status      VARCHAR(20)   NOT NULL DEFAULT 'NEW'  COMMENT '订单状态',
    version     INT           NOT NULL DEFAULT 0      COMMENT '乐观锁版本号',
    updated_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（死锁演示）';
