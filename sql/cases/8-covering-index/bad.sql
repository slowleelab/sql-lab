-- bad.sql: SELECT * 查询所有字段，需要回表读取 description（TEXT 长文本）
-- 即使有 idx_category_price 索引，也要回表取完整行数据
SELECT *
FROM t_product
WHERE category_id = 50
ORDER BY price
LIMIT 100;
