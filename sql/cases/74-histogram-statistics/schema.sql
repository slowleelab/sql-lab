-- ============================================================
-- 案例三十五: 直方图统计优化选错索引
-- 场景: t_task 表 status 分布极度不均（99%为0），优化器不知分布会选错索引
-- 8.0 直方图记录列值分布，帮助优化器做出正确的索引选择
-- ============================================================

DROP TABLE IF EXISTS t_task;
CREATE TABLE t_task (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL                COMMENT '用户ID',
    status      TINYINT      NOT NULL DEFAULT 0      COMMENT '任务状态: 0待处理 1处理中 2已完成',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='任务表（直方图演示）';
