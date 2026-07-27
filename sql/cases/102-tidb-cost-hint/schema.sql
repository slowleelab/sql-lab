-- TiDB Cost Model 与优化器 Hint 进阶
-- TiDB 中 ENGINE=InnoDB 会被忽略，但保留以兼容 MySQL 写法

DROP TABLE IF EXISTS t_hint_test;
CREATE TABLE t_hint_test (
    id         BIGINT      NOT NULL AUTO_INCREMENT,
    user_id    BIGINT      NOT NULL,
    status     TINYINT     NOT NULL DEFAULT 1,
    city       VARCHAR(20) NOT NULL,
    score      INT         NOT NULL DEFAULT 0,
    created_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_status (status),
    KEY idx_city (city),
    KEY idx_score (score)
);
