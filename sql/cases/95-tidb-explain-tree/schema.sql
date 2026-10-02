-- TiDB EXPLAIN 算子树解读
-- TiDB 中 ENGINE=InnoDB 会被忽略，但保留以兼容 MySQL 写法

DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    name     VARCHAR(50) NOT NULL,
    age      INT         NOT NULL,
    city     VARCHAR(20) NOT NULL,
    salary   DECIMAL(12,2) DEFAULT NULL,
    PRIMARY KEY (id),
    KEY idx_city (city),
    KEY idx_age (age)
);

DROP TABLE IF EXISTS t_order;
CREATE TABLE t_order (
    id        BIGINT      NOT NULL AUTO_INCREMENT,
    user_id   BIGINT      NOT NULL,
    amount    DECIMAL(10,2) NOT NULL,
    status    TINYINT     NOT NULL DEFAULT 0,
    created_at DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_status (status),
    KEY idx_created (created_at)
);
