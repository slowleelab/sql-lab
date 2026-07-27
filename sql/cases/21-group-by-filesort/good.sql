-- good.sql: 加索引后的查询（需先执行 setup-good.sql 建 idx_city 索引）
-- city 字段有索引后，GROUP BY 利用索引有序性，消除临时表
SELECT city, COUNT(*) AS cnt, AVG(amount) AS avg_amount
FROM t_order_stat
GROUP BY city;
