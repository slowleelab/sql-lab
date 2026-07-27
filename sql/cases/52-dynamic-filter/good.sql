-- 联合索引优化后：idx_category_status_price (category_id, status, price)
-- 三个条件都能利用索引：category_id 等值定位 + status 等值进一步过滤 + price 范围扫描
-- 大幅减少回表行数，只需对最终少量候选行回表取 name/brand_id/sales
-- 需先执行 setup-good.sql 创建联合索引
SELECT id, name, category_id, brand_id, price, status, sales
FROM t_goods
WHERE category_id = 10
  AND status = 1
  AND price BETWEEN 100 AND 500
ORDER BY sales DESC
LIMIT 20;
