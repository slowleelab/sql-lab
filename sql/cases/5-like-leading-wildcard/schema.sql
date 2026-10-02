-- ============================================================
-- 案例五: LIKE 前导通配符致索引失效
-- 场景: 用户表 username 有索引，LIKE '%keyword%' 索引失效
-- ============================================================

DROP TABLE IF EXISTS t_user_search;
CREATE TABLE t_user_search (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    nickname     VARCHAR(50)  NOT NULL              COMMENT '昵称',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_username (username),
    KEY idx_phone (phone)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
