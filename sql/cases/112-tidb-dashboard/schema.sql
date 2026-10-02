DROP TABLE IF EXISTS t_diag;
CREATE TABLE t_diag (
    id         BIGINT      NOT NULL AUTO_INCREMENT,
    user_id    BIGINT      NOT NULL,
    name       VARCHAR(50) NOT NULL,
    age        INT         NOT NULL DEFAULT 0,
    city       VARCHAR(20) NOT NULL,
    score      INT         NOT NULL DEFAULT 0,
    created_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_city (city),
    KEY idx_created (created_at)
);
