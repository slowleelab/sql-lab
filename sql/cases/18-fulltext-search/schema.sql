-- ============================================================
-- 案例七十七: 全文索引 FULLTEXT 替代 LIKE
-- 场景: 文章表 content 字段中文搜索，LIKE '%关键词%' 全表扫描
-- ============================================================

-- bad 表：content 字段无 FULLTEXT 索引，LIKE '%关键词%' 只能全表扫描
DROP TABLE IF EXISTS t_article_search_bad;
CREATE TABLE t_article_search_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL              COMMENT '标题',
    author       VARCHAR(50)   NOT NULL              COMMENT '作者',
    content      TEXT          NOT NULL              COMMENT '正文（中文内容）',
    category     VARCHAR(20)   NOT NULL              COMMENT '分类',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章表（无全文索引）';

-- good 表：content 字段加 FULLTEXT 索引，使用 ngram 分词器支持中文
DROP TABLE IF EXISTS t_article_search_good;
CREATE TABLE t_article_search_good (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    title        VARCHAR(200)  NOT NULL              COMMENT '标题',
    author       VARCHAR(50)   NOT NULL              COMMENT '作者',
    content      TEXT          NOT NULL              COMMENT '正文（中文内容）',
    category     VARCHAR(20)   NOT NULL              COMMENT '分类',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category (category),
    FULLTEXT INDEX ft_content (content) WITH PARSER ngram
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='文章表（FULLTEXT + ngram）';

-- 注意: FULLTEXT 索引建表时直接创建会随数据写入同步构建。
-- 生产环境对已有大表添加 FULLTEXT，推荐：
--   ALTER TABLE t_article_search_good
--     ADD FULLTEXT INDEX ft_content (content) WITH PARSER ngram;
-- ngram 分词器是 MySQL 5.7.6+ 内置插件，默认 ngram_token_size=2（按 2 字符切分中文）。
