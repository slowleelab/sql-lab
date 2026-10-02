-- ============================================================
-- 案例二十一: 大表 DELETE 分批
-- 场景: 日志表大量 DEBUG 数据需清理，一次性 DELETE 导致大事务
-- ============================================================

DROP TABLE IF EXISTS t_log;
CREATE TABLE t_log (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    level        TINYINT      NOT NULL              COMMENT '日志级别: 0=DEBUG 1=INFO 2=WARN 3=ERROR',
    message      VARCHAR(500) NOT NULL              COMMENT '日志内容',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_level_created (level, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='日志表';
