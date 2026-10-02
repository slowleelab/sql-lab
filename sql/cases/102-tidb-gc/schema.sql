DROP TABLE IF EXISTS t_gc_test;
CREATE TABLE t_gc_test (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    data     VARCHAR(200) NOT NULL,
    status   TINYINT     NOT NULL DEFAULT 0,
    created_at DATETIME  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_status (status)
);
