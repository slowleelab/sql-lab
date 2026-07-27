-- ============================================================
-- 案例七十三: 大字段垂直拆表
-- 场景: 文章表含 content TEXT 正文，列表页只需标题和摘要
-- ============================================================

-- bad 表：正文和元数据混在一张表
DROP TABLE IF EXISTS t_article_bad;
CREATE TABLE t_article_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL              COMMENT '标题',
    author       VARCHAR(50)   NOT NULL              COMMENT '作者',
    category     VARCHAR(20)   NOT NULL              COMMENT '分类',
    views        INT           NOT NULL DEFAULT 0    COMMENT '浏览量',
    content      TEXT          NOT NULL              COMMENT '正文（平均 5KB）',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category_created (category, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章表（含正文）';

-- good 表：拆为主表 + 扩展表
DROP TABLE IF EXISTS t_article_good;
CREATE TABLE t_article_good (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL              COMMENT '标题',
    author       VARCHAR(50)   NOT NULL              COMMENT '作者',
    category     VARCHAR(20)   NOT NULL              COMMENT '分类',
    views        INT           NOT NULL DEFAULT 0    COMMENT '浏览量',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category_created (category, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章主表（不含正文）';

DROP TABLE IF EXISTS t_article_content;
CREATE TABLE t_article_content (
    article_id   BIGINT        NOT NULL              COMMENT '关联文章ID',
    content      MEDIUMTEXT    NOT NULL              COMMENT '正文',
    PRIMARY KEY (article_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章正文扩展表';
