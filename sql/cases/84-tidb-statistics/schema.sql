-- TiDB 统计信息管理
-- TiDB 中 ENGINE=InnoDB 会被忽略，但保留以兼容 MySQL 写法

DROP TABLE IF EXISTS t_stats;
CREATE TABLE t_stats (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    status   TINYINT     NOT NULL DEFAULT 0,
    city     VARCHAR(20) NOT NULL,
    amount   DECIMAL(10,2) DEFAULT NULL,
    created_at DATETIME  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_city (city),
    KEY idx_user (user_id)
);
