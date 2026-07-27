-- ============================================================
-- 案例十九: 大表加索引 Online DDL
-- 场景: 生产环境大表（20万行模拟）加索引，对比不同 DDL 算法
-- ============================================================

DROP TABLE IF EXISTS t_big_table;
CREATE TABLE t_big_table (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    user_id      BIGINT       NOT NULL              COMMENT '用户ID',
    content      VARCHAR(500) NOT NULL              COMMENT '内容',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='大表（仅主键，演示加索引）';
