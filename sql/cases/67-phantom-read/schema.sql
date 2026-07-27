-- ============================================================
-- 案例三十: 幻读问题与解决
-- 场景: RR下事务A两次查询同一范围得到不同行数（幻读），间隙锁防止幻读
-- ============================================================

DROP TABLE IF EXISTS t_transaction_log;
CREATE TABLE t_transaction_log (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    tx_amount   DECIMAL(12,2) NOT NULL              COMMENT '交易金额',
    created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_amount (tx_amount)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='交易日志表（幻读演示）';
