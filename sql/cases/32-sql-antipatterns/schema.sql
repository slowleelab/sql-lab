-- ============================================================
-- 案例七十九: SQL 反模式与正确写法量化对比
-- 场景: 三种常见反模式对比
--   1. SELECT * 回表代价 vs 只查必要列（可能走覆盖索引）
--   2. OR 条件 index_merge 低效 vs UNION ALL 拆分
--   3. COUNT(col) 语义错误 vs COUNT(*)
-- ============================================================

DROP TABLE IF EXISTS t_anti_test;
CREATE TABLE t_anti_test (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    user_id     BIGINT        NOT NULL              COMMENT '用户ID',
    order_no    VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount      DECIMAL(10,2) NOT NULL              COMMENT '金额',
    status      TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    remark      VARCHAR(100)  DEFAULT NULL          COMMENT '备注(可能为空)',
    created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id),
    KEY idx_status (status),
    KEY idx_user_status (user_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='反模式测试表';
