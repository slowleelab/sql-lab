-- ============================================================
-- 案例五十: 分区表 RANGE 分区优化
-- 场景: 日志表按月 RANGE 分区，查询某月数据触发分区裁剪
-- ============================================================

-- 普通表（无分区）: bad 场景使用，全表扫描
DROP TABLE IF EXISTS t_partition_log;
CREATE TABLE t_partition_log (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    log_level    TINYINT       NOT NULL DEFAULT 0    COMMENT '日志级别: 0=DEBUG 1=INFO 2=WARN 3=ERROR',
    message      VARCHAR(500)  NOT NULL              COMMENT '日志内容',
    created_at   DATETIME      NOT NULL              COMMENT '日志时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='日志表(普通无分区)';

-- 注意: 分区表的 DDL 在 setup-good.sql 中，
-- 因为分区表需要 PRIMARY KEY 包含分区键 (id, created_at)，
-- 与普通表结构不同，需单独建表。
