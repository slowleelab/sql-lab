-- ============================================================
-- 案例二十七: 间隙锁导致插入阻塞
-- 场景: RR隔离级别下，事务A范围查询 FOR UPDATE 加间隙锁，事务B插入该间隙被阻塞
-- ============================================================

DROP TABLE IF EXISTS t_account;
CREATE TABLE t_account (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    account_no  VARCHAR(32)   NOT NULL              COMMENT '账号编号',
    balance     DECIMAL(12,2) NOT NULL DEFAULT 0.00  COMMENT '账户余额',
    created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='账户表（间隙锁演示）';
