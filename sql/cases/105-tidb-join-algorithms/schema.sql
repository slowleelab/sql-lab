DROP TABLE IF EXISTS t_join_a;
CREATE TABLE t_join_a (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    a_name   VARCHAR(50) NOT NULL,
    a_val    INT         NOT NULL,
    PRIMARY KEY (id),
    KEY idx_val (a_val)
);

DROP TABLE IF EXISTS t_join_b;
CREATE TABLE t_join_b (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    b_name   VARCHAR(50) NOT NULL,
    b_val    INT         NOT NULL,
    PRIMARY KEY (id),
    KEY idx_val (b_val)
);

DROP TABLE IF EXISTS t_join_c;
CREATE TABLE t_join_c (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    c_name   VARCHAR(50) NOT NULL,
    c_val    INT         NOT NULL,
    PRIMARY KEY (id)
);
