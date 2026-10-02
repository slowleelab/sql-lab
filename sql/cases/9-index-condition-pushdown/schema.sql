-- ============================================================
-- 案例九: 索引下推 ICP（Index Condition Pushdown）
-- 场景: 用户表联合索引 (phone_prefix, name)，按 phone_prefix 等值 + name LIKE 查询
-- ICP 将 name LIKE 条件下推到索引层过滤，减少回表次数
-- ============================================================

DROP TABLE IF EXISTS t_user_icp;
CREATE TABLE t_user_icp (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    phone_prefix VARCHAR(4)   NOT NULL              COMMENT '手机号前4位',
    name         VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '完整手机号',
    city         VARCHAR(20)  NOT NULL              COMMENT '城市',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_prefix_name (phone_prefix, name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表(ICP演示)';
