DROP TABLE IF EXISTS t_account;
CREATE TABLE t_account (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_name VARCHAR(50) NOT NULL,
    balance  DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    PRIMARY KEY (id),
    UNIQUE KEY uk_user (user_name)
);
