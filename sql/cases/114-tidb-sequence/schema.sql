-- TiDB 分布式 Sequence：建表与 Sequence 对象
-- 对比三种分布式 ID 方案

-- 方案 A：AUTO_INCREMENT（单节点递增，分布式下有空洞/不连续）
DROP TABLE IF EXISTS t_auto_inc;
CREATE TABLE t_auto_inc (
    id   BIGINT NOT NULL AUTO_INCREMENT,
    name VARCHAR(50) NOT NULL,
    val  INT    NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
);

-- 方案 B：AUTO_RANDOM（哈希打散高位，避免写热点，不保证顺序）
DROP TABLE IF EXISTS t_auto_rand;
CREATE TABLE t_auto_rand (
    id   BIGINT NOT NULL AUTO_RANDOM,
    name VARCHAR(50) NOT NULL,
    val  INT    NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
);

-- 方案 C：Sequence（全局递增，CACHE 预分配减少 TSO 开销）
DROP SEQUENCE IF EXISTS seq_global;
CREATE SEQUENCE seq_global
    START WITH 1
    INCREMENT BY 1
    CACHE 1000;

DROP TABLE IF EXISTS t_seq;
CREATE TABLE t_seq (
    id   BIGINT NOT NULL DEFAULT NEXT VALUE FOR seq_global,
    name VARCHAR(50) NOT NULL,
    val  INT    NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
);
