-- ============================================================
-- 案例五十七: 索引跳跃扫描 Skip Scan
-- 场景: 联合索引 (gender, created_at)，gender 只有 2 个值（低基数），
--       查询 WHERE created_at > '2026-01-01' 跳过前导列 gender
-- ============================================================

DROP TABLE IF EXISTS t_user_skip;
CREATE TABLE t_user_skip (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    gender       CHAR(1)      NOT NULL              COMMENT '性别: M/F',
    created_at   DATETIME     NOT NULL              COMMENT '创建时间',
    email        VARCHAR(100) NOT NULL              COMMENT '邮箱',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    PRIMARY KEY (id),
    KEY idx_gender_created (gender, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
