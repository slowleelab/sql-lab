-- ============================================================
-- 案例三十二: 唯一索引并发插入冲突
-- 场景: 并发 INSERT 同一唯一键冲突，用 INSERT ... ON DUPLICATE KEY UPDATE 解决
-- ============================================================

DROP TABLE IF EXISTS t_unique_test;
CREATE TABLE t_unique_test (
    id        BIGINT      NOT NULL AUTO_INCREMENT,
    uk_code   VARCHAR(32) NOT NULL              COMMENT '唯一编码（唯一索引）',
    counter   INT         NOT NULL DEFAULT 0    COMMENT '计数器',
    updated_at DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_code (uk_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='唯一键测试表（并发插入演示）';
