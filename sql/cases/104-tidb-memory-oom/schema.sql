-- TiDB 内存控制与 OOM 防护

DROP TABLE IF EXISTS t_oom_test;
CREATE TABLE t_oom_test (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    group_id INT         NOT NULL,
    data     VARCHAR(200) NOT NULL,
    value    INT         NOT NULL,
    created_at DATETIME  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_group (group_id)
);
