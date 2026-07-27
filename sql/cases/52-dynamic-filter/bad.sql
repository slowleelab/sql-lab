-- 多条件组合筛选：category_id=10 AND status=1 AND price BETWEEN 100 AND 500
-- 只有单列索引，优化器可能选 idx_category 或 idx_status 之一
-- 选定一个索引后，其余条件只能回表逐行过滤，大量无效回表
SELECT id, name, category_id, brand_id, price, status, sales
FROM t_goods
WHERE category_id = 10
  AND status = 1
  AND price BETWEEN 100 AND 500
ORDER BY sales DESC
LIMIT 20;
