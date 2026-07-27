DROP TABLE IF EXISTS t_pushdown;
CREATE TABLE t_pushdown (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    age      INT         NOT NULL,
    city     VARCHAR(20) NOT NULL,
    bio      TEXT        DEFAULT NULL,
    score    DECIMAL(5,2) DEFAULT 0.00,
    created_at DATETIME  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_age (age),
    KEY idx_city (city)
);

DROP TABLE IF EXISTS t_pushdown_2;
CREATE TABLE t_pushdown_2 (
    id      BIGINT      NOT NULL AUTO_INCREMENT,
    name    VARCHAR(50) NOT NULL,
    value   INT         NOT NULL,
    PRIMARY KEY (id),
    KEY idx_value (value)
);
