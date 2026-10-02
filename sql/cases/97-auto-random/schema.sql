-- 对比 AUTO_INCREMENT（热点）vs AUTO_RANDOM（分散）的写入性能

DROP TABLE IF EXISTS t_auto_inc;
CREATE TABLE t_auto_inc (
    id    BIGINT NOT NULL AUTO_INCREMENT,
    name  VARCHAR(50) NOT NULL,
    val   INT    NOT NULL,
    PRIMARY KEY (id)
);

DROP TABLE IF EXISTS t_auto_random;
CREATE TABLE t_auto_random (
    id    BIGINT NOT NULL AUTO_RANDOM,
    name  VARCHAR(50) NOT NULL,
    val   INT    NOT NULL,
    PRIMARY KEY (id)
);

-- 非主键场景：使用 SHARD_ROW_ID_BITS 避免热点
DROP TABLE IF EXISTS t_shard_row;
CREATE TABLE t_shard_row (
    id    BIGINT NOT NULL AUTO_INCREMENT,
    name  VARCHAR(50) NOT NULL,
    val   INT    NOT NULL,
    PRIMARY KEY (id)
) SHARD_ROW_ID_BITS = 4;
