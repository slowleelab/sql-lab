-- ============================================================
-- 案例五十一: 大表批量 INSERT 优化
-- 场景: 需要导入 10 万行数据，对比单行与批量插入效率
-- ============================================================

DROP TABLE IF EXISTS t_batch_data;
CREATE TABLE t_batch_data (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_name    VARCHAR(50)   NOT NULL              COMMENT '用户名',
    email        VARCHAR(100)  NOT NULL              COMMENT '邮箱',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='批量数据表';
