-- ============================================================
-- 案例三十四: 函数索引优化 DATE 函数查询
-- 场景: 访问日志按日期查询，WHERE DATE(created_at) = '...' 致索引失效
-- 8.0 支持函数索引 ((DATE(created_at)))，可对函数表达式建索引
-- ============================================================

DROP TABLE IF EXISTS t_access_log;
CREATE TABLE t_access_log (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL                COMMENT '用户ID',
    ip_addr     VARCHAR(45)  NOT NULL                COMMENT 'IP地址',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '访问时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='访问日志表（函数索引演示）';
