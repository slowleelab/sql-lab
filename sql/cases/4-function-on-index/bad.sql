-- bad.sql: 对索引列 created_at 套用 DATE() 函数
-- 等价写法 DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01' 同样会使索引失效
-- 因为对列做函数运算后，B+ 树中存储的原值无法直接匹配，索引失效，退化为全表扫描
SELECT id, user_id, order_no, amount, created_at
FROM t_order_func
WHERE DATE(created_at) = '2026-07-01';
