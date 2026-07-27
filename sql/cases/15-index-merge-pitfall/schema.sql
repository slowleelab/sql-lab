-- ============================================================
-- 案例五十六: 索引合并 Index Merge 陷阱
-- 场景: WHERE status=1 OR city='北京'，两个条件各自有索引，
--       MySQL 选择 index_merge(union)，合并开销大于全表扫描
-- ============================================================

DROP TABLE IF EXISTS t_user_merge;
CREATE TABLE t_user_merge (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '状态: 0-4',
    city         VARCHAR(20)  NOT NULL              COMMENT '城市',
    email        VARCHAR(100) NOT NULL              COMMENT '邮箱',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_city (city)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
