-- ============================================================
-- 案例二十: TEXT/BLOB 字段性能陷阱
-- 场景: 文章表含 TEXT 字段，SELECT * 回表读取大文本导致性能差
-- ============================================================

DROP TABLE IF EXISTS t_article;
CREATE TABLE t_article (
    id           INT          NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200) NOT NULL              COMMENT '标题',
    author       VARCHAR(50)  NOT NULL              COMMENT '作者',
    category     VARCHAR(20)  NOT NULL              COMMENT '分类',
    content      TEXT         NOT NULL              COMMENT '正文（TEXT 大字段）',
    views        INT          NOT NULL DEFAULT 0    COMMENT '浏览量',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_category_created (category, created_at),
    KEY idx_views (views)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章表（含 TEXT 大字段）';
