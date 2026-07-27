-- ============================================================
-- 案例五十五: 软删除设计模式
-- 场景: 用 deleted_at 标记删除，查询需 WHERE deleted_at IS NULL 过滤
--        索引设计不当导致全表扫描 + filesort
-- ============================================================

DROP TABLE IF EXISTS t_document_soft;
CREATE TABLE t_document_soft (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200) NOT NULL              COMMENT '文档标题',
    content      TEXT         NOT NULL              COMMENT '文档内容',
    author_id    BIGINT       NOT NULL              COMMENT '作者ID',
    deleted_at   DATETIME     NULL DEFAULT NULL     COMMENT '软删除时间，NULL 表示未删除',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_author (author_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文档表(软删除)';
