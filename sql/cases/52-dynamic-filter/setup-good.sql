-- setup-good.sql: 替换单列索引为联合索引
-- 联合索引 (category_id, status, price) 设计依据:
--   1. category_id 等值查询 -> 放最左，定位最精准
--   2. status 等值查询 -> 放第二，进一步缩小范围
--   3. price 范围查询 -> 放最后，利用索引有序性做范围扫描
-- 等值列在前、范围列在后
ALTER TABLE t_goods DROP INDEX idx_category;
ALTER TABLE t_goods DROP INDEX idx_status;
ALTER TABLE t_goods DROP INDEX idx_price;
ALTER TABLE t_goods ADD KEY idx_category_status_price (category_id, status, price);
