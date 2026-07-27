-- bad.sql: 按 city 分组统计，city 字段没有索引
-- Extra 出现 Using temporary; Using filesort
-- MySQL 需要创建临时表来分组，再排序
SELECT city, COUNT(*) AS cnt, AVG(amount) AS avg_amount
FROM t_order_stat
GROUP BY city;
