DROP TABLE IF EXISTS t_plan_cache;
CREATE TABLE t_plan_cache (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    city     VARCHAR(20) NOT NULL,
    score    INT         NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_city (city)
);
