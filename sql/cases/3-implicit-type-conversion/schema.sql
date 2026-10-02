-- ============================================================
-- 案例三: 隐式类型转换致索引失效
-- 场景: 用户表通过手机号查询，字段是 VARCHAR 但传了数字
-- ============================================================

DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    email        VARCHAR(100) DEFAULT NULL           COMMENT '邮箱',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '1正常/0禁用',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_phone (phone),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
