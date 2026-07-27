-- ============================================================
-- 案例六十六: 长事务危害
-- 场景: 事务中先加锁再执行耗时操作（如调用外部支付接口），
--       锁持有时间过长导致并发阻塞和 undo log 膨胀
-- ============================================================

DROP TABLE IF EXISTS t_account;
CREATE TABLE t_account (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    account_no  VARCHAR(32)   NOT NULL              COMMENT '账号编号',
    user_name   VARCHAR(50)   NOT NULL              COMMENT '用户名',
    balance     DECIMAL(12,2) NOT NULL DEFAULT 0.00 COMMENT '账户余额',
    status      TINYINT       NOT NULL DEFAULT 1    COMMENT '状态: 0冻结 1正常',
    created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_account_no (account_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='账户表（长事务演示）';
