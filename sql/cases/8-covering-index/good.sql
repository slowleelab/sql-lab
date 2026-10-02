-- good.sql: 只查索引覆盖的字段（category_id, price + 主键 id）
-- idx_category_price (category_id, price) 包含了查询所需的所有列
-- 加上 InnoDB 主键自动附加到索引，id 也在索引中
-- Extra 显示 Using index，完全不需要回表
SELECT id, category_id, price
FROM t_product
WHERE category_id = 50
ORDER BY price
LIMIT 100;
