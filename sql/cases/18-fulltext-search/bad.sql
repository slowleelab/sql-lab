-- bad.sql: LIKE '%关键词%' 在 content 上做中文搜索
-- 前导通配符 % 导致无法走任何索引，content 字段无 FULLTEXT 索引
-- 优化器只能全表扫描 20 万行，逐行对 TEXT 字段做子串匹配
-- TEXT 字段可能存储在溢出页，每行匹配还需额外读取溢出页，I/O 代价极高
SELECT id, title, author, content, category
FROM t_article_search_bad
WHERE content LIKE '%性能优化%';
