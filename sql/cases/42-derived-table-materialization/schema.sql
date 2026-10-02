-- ============================================================
-- 案例四十九: 派生表物化优化
-- 场景: 访问日志表 FROM 子查询物化，外层 WHERE 无法下推
-- ============================================================

DROP TABLE IF EXISTS t_access_log;
CREATE TABLE t_access_log (
    id             BIGINT       NOT NULL AUTO_INCREMENT,
    user_id        BIGINT       NOT NULL              COMMENT '用户ID',
    access_url     VARCHAR(255) NOT NULL              COMMENT '访问URL',
    response_time  INT          NOT NULL DEFAULT 0    COMMENT '响应时间(ms)',
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '访问时间',
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='访问日志表';
