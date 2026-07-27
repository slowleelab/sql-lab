-- bad.sql: 列表查询，即使不查 content 字段，InnoDB 页内仍有 TEXT 指针
-- 导致每页存放的行数少，同样扫描 20 行需要读取更多数据页
-- Buffer Pool 命中率低，大量 I/O 被浪费在"路过" TEXT 指针上

-- 列表页查询（不查 content，但表结构中仍有 TEXT）
SELECT id, title, author, category, views, created_at
FROM t_article_bad
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;

-- 详情页查询（需要 content）
SELECT id, title, author, category, views, content, created_at
FROM t_article_bad
WHERE id = 1;
