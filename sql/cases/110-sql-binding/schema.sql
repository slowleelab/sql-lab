-- ============================================================
-- 案例 96: SQL Binding 执行计划锁定 (SPM)
-- 场景: t_spm_test 订单表，status 分布严重不均（90% 为 1）
--       优化器因统计信息偏差可能选错计划
-- ============================================================

DROP TABLE IF EXISTS t_spm_test;
CREATE TABLE t_spm_test (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL              COMMENT '用户ID',
    status      TINYINT      NOT NULL DEFAULT 0    COMMENT '状态: 0-待处理 1-已完成 2-已取消',
    city        VARCHAR(20)  NOT NULL              COMMENT '城市',
    amount      DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '金额',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_city (city),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='SPM绑定测试表(状态倾斜)';
