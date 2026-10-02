-- ============================================================
-- 案例: TiDB 在线 DDL 机制
-- 场景: 验证 TiDB DDL 不阻塞读写，多阶段状态滑移
-- ============================================================

DROP TABLE IF EXISTS t_ddl_test;
CREATE TABLE t_ddl_test (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    email    VARCHAR(100) NOT NULL,
    age      INT         NOT NULL,
    city     VARCHAR(20) NOT NULL,
    PRIMARY KEY (id),
    KEY idx_city (city)
);
