-- ============================================================
-- 案例四十五: UNION vs UNION ALL
-- 场景: 合并两个数据源的 code/name，两表数据无交叉
--       UNION 自动去重需临时表，UNION ALL 直接拼接更快
-- ============================================================

-- 数据源 A: 10 万行
DROP TABLE IF EXISTS t_source_a;
CREATE TABLE t_source_a (
    id    BIGINT       NOT NULL AUTO_INCREMENT,
    code  VARCHAR(20)  NOT NULL              COMMENT '编码',
    name  VARCHAR(50)  NOT NULL              COMMENT '名称',
    PRIMARY KEY (id),
    KEY idx_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='数据源A';

-- 数据源 B: 10 万行
DROP TABLE IF EXISTS t_source_b;
CREATE TABLE t_source_b (
    id    BIGINT       NOT NULL AUTO_INCREMENT,
    code  VARCHAR(20)  NOT NULL              COMMENT '编码',
    name  VARCHAR(50)  NOT NULL              COMMENT '名称',
    PRIMARY KEY (id),
    KEY idx_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='数据源B';
