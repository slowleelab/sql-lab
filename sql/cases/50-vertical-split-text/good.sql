-- good.sql: 拆表后，主表每页容纳更多行，列表查询更快
-- 详情页通过 JOIN 取正文

-- 列表页查询（主表不含 TEXT，每页更多行，Buffer Pool 命中率高）
SELECT id, title, author, category, views, created_at
FROM t_article_good
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;

-- 详情页查询（JOIN 扩展表取正文，只查一条）
SELECT a.id, a.title, a.author, a.category, a.views, c.content, a.created_at
FROM t_article_good a
LEFT JOIN t_article_content c ON a.id = c.article_id
WHERE a.id = 1;

-- 对比两张表每页平均行数（InnoDB 默认页 16KB）
-- bad 表：每行约 5KB -> 每页约 3 行
-- good 表：每行约 0.2KB -> 每页约 80 行
-- 同样扫描 20 行：
--   bad 表：读取约 7 个数据页
--   good 表：读取约 1 个数据页

-- 查看表大小对比
SELECT
    TABLE_NAME,
    TABLE_ROWS,
    ROUND(DATA_LENGTH / 1024 / 1024, 2) AS data_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('t_article_bad', 't_article_good', 't_article_content');
