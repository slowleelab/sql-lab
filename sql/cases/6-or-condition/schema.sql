-- ============================================================
-- 案例六: OR 条件与索引合并
-- 场景: WHERE phone='x' OR city='北京'，city 无索引，OR 中存在
--       无法走索引的条件，导致整体退化为全表扫描
-- ============================================================

DROP TABLE IF EXISTS t_user_or;
CREATE TABLE t_user_or (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '1正常/0禁用',
    city         VARCHAR(20)  NOT NULL              COMMENT '城市',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_phone (phone),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
