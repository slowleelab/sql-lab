-- ============================================================
-- 案例四十六: ORDER BY LIMIT 无索引优化
-- 场景: 消息表按 created_at 倒序取最新 10 条，created_at 无索引
--       全表扫描 + filesort，加索引后走索引有序直接取前 N
-- ============================================================

DROP TABLE IF EXISTS t_message;
CREATE TABLE t_message (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL              COMMENT '用户ID',
    content     VARCHAR(500) NOT NULL              COMMENT '消息内容',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='消息表(ORDER BY LIMIT演示)';
