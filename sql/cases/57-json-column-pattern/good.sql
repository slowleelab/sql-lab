-- good.sql: 通过虚拟列 color 走索引查询（需先执行 setup-good.sql 建虚拟列+索引）
-- 虚拟列 color 由 attrs->'$.color' 派生，查询时直接走 idx_color 索引
-- 也可写成 WHERE attrs->'$.color' = 'red'，优化器会自动匹配虚拟列索引
SELECT *
FROM t_product_json
WHERE color = 'red';
