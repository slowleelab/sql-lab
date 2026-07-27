-- good.sql: FULLTEXT 索引 + MATCH AGAINST 实现中文全文检索
-- content 字段建有 FULLTEXT INDEX ft_content WITH PARSER ngram
-- ngram 分词器将中文按 2 字符切分:
--   "性能优化" -> "性能" + "能优" + "优化"
-- 查询时直接查倒排索引定位文档，无需逐行扫描 content
-- IN BOOLEAN MODE 支持精确短语匹配（等价于 AND 语义），与 LIKE '%性能优化%' 语义最接近

-- 建表时已创建 FULLTEXT 索引；若对已有表添加，DDL 如下:
--   ALTER TABLE t_article_search_good
--     ADD FULLTEXT INDEX ft_content (content) WITH PARSER ngram;

SELECT id, title, author, content, category
FROM t_article_search_good
WHERE MATCH(content) AGAINST('性能优化' IN BOOLEAN MODE);
