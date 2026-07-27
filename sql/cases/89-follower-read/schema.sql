-- TiDB Follower Read 读写分离
-- 利用 Raft 协议的 Follower 副本分担 Leader 读压力

DROP TABLE IF EXISTS t_follower;
CREATE TABLE t_follower (
    id       BIGINT      NOT NULL AUTO_INCREMENT,
    user_id  BIGINT      NOT NULL,
    name     VARCHAR(50) NOT NULL,
    score    DECIMAL(5,2) DEFAULT 0.00,
    city     VARCHAR(20) NOT NULL,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_city (city)
);
