DROP TABLE IF EXISTS t_lookup;
CREATE TABLE t_lookup (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    email    VARCHAR(100) NOT NULL,
    age      INT         NOT NULL,
    city     VARCHAR(20) NOT NULL,
    bio      TEXT        DEFAULT NULL,
    score    DECIMAL(5,2) DEFAULT 0.00,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_city (city),
    KEY idx_age_city (age, city)
);

-- Cluster Index 表（主键即聚簇索引，避免额外回表）
DROP TABLE IF EXISTS t_cluster_lookup;
CREATE TABLE t_cluster_lookup (
    id       BIGINT      NOT NULL,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    age      INT         NOT NULL,
    city     VARCHAR(20) NOT NULL,
    PRIMARY KEY (id)  /* CLUSTERED */,
    KEY idx_city (city)
);
