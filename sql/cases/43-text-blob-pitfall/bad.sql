-- SELECT * 查询：回表时连 TEXT 大字段一起读入，每行约 2KB 的 content 被加载
-- 虽然只取 20 行，但 InnoDB 回表时 TEXT 可能存储在溢出页（off-page），
-- 读取 TEXT 需要额外的磁盘 I/O 追踪溢出页链，大幅增加延迟
SELECT * FROM t_article
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
