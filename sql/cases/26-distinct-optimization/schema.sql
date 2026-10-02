-- ============================================================
-- 案例四十三: DISTINCT 优化
-- 场景: 访问日志表按 user_id 去重，无索引时需临时表去重
-- ============================================================

DROP TABLE IF EXISTS t_visit_log;
CREATE TABLE t_visit_log (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL              COMMENT '用户ID',
    page_url    VARCHAR(255) NOT NULL              COMMENT '访问页面',
    visit_time  DATETIME     NOT NULL              COMMENT '访问时间',
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='访问日志表(DISTINCT优化演示)';
