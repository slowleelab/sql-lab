-- bad.sql: 直接用 JSON_EXTRACT 查询 JSON 内部字段（全表扫描）
-- JSON_EXTRACT 是函数，无法直接在 attrs 上走索引，需逐行解析 JSON 再比较
SELECT *
FROM t_product_json
WHERE JSON_EXTRACT(attrs, '$.color') = 'red';
