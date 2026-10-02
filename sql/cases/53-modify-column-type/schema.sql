-- ============================================================
-- 案例四十五: 修改字段类型的锁行为差异
-- 场景: 100 万行用户表，phone 字段从 VARCHAR(50) 改为 VARCHAR(20)
-- ============================================================

DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    nickname     VARCHAR(64)  NOT NULL              COMMENT '用户昵称',
    phone        VARCHAR(50)  NOT NULL DEFAULT ''   COMMENT '手机号（需改为VARCHAR(20)）',
    email        VARCHAR(100) NOT NULL DEFAULT ''   COMMENT '邮箱',
    age          INT          NOT NULL DEFAULT 0    COMMENT '年龄',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '1正常/0禁用',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间',
    PRIMARY KEY (id),
    KEY idx_phone (phone),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表（演示修改列类型）';
