-- ============================================================
-- 案例三十三: 降序索引消除 filesort
-- 场景: 事件日志按 event_type 过滤后按 created_at DESC 取最近 20 条
-- 5.7 中 DESC 索引实际按 ASC 存储，ORDER BY DESC 仍需 filesort
-- 8.0 支持真正的降序索引，可消除 filesort
-- ============================================================

DROP TABLE IF EXISTS t_event_log;
CREATE TABLE t_event_log (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    event_type  VARCHAR(20)  NOT NULL                COMMENT '事件类型',
    event_data  VARCHAR(500) NOT NULL                COMMENT '事件数据',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_type_created (event_type, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='事件日志表（降序索引演示）';
