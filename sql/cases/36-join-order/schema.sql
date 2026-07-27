-- ============================================================
-- 案例十八: 多表 JOIN 顺序控制
-- 场景: 3表 JOIN，用 STRAIGHT_JOIN 控制最优 JOIN 顺序
-- ============================================================

-- 小表: 1000 行
DROP TABLE IF EXISTS t_small;
CREATE TABLE t_small (
    id     BIGINT NOT NULL AUTO_INCREMENT,
    val    INT    NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='小表';

-- 中表: 5 万行
DROP TABLE IF EXISTS t_medium;
CREATE TABLE t_medium (
    id        BIGINT NOT NULL AUTO_INCREMENT,
    small_id  BIGINT NOT NULL              COMMENT '关联小表',
    val       INT    NOT NULL,
    PRIMARY KEY (id),
    KEY idx_small_id (small_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='中表';

-- 大表: 20 万行
DROP TABLE IF EXISTS t_large;
CREATE TABLE t_large (
    id        BIGINT NOT NULL AUTO_INCREMENT,
    medium_id BIGINT NOT NULL              COMMENT '关联中表',
    val       INT    NOT NULL,
    PRIMARY KEY (id),
    KEY idx_medium_id (medium_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='大表';
