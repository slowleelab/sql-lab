-- ============================================================
-- 案例七十一: 游标分页替代深分页
-- 场景: 资讯流/朋友圈/消息列表，用户持续向下翻页（下一页/上一页）
-- ============================================================

DROP TABLE IF EXISTS t_feed;
CREATE TABLE t_feed (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '发布者ID',
    content      VARCHAR(500)  NOT NULL              COMMENT '内容',
    status       TINYINT       NOT NULL DEFAULT 1    COMMENT '1已发布/2审核中/3已删除',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '发布时间',
    PRIMARY KEY (id),
    KEY idx_status_created_id (status, created_at, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='资讯流表';
