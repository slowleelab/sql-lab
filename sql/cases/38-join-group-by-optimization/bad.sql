-- bad.sql: 先 JOIN 100 万行再 GROUP BY（大临时表）
--
-- 原理:
--   1. 先将 t_order(100万行) 与 t_user(1万行) 做 JOIN，产生 100 万行中间结果
--   2. 对 100 万行中间结果按 u.region 做 GROUP BY 聚合
--   3. GROUP BY 无法利用索引（region 在 t_user 上，JOIN 后顺序被打乱）
--      -> Using temporary; Using filesort
--   4. 临时表需容纳 100 万行的 (region, order_count, total_amount) 聚合中间态
--      内存临时表放不下时溢出到磁盘，性能急剧下降
--
--   核心问题: JOIN 在聚合之前执行，放大了参与聚合的数据量
SELECT
    u.region                  AS region,
    COUNT(*)                  AS order_count,
    SUM(o.amount)             AS total_amount
FROM t_order o
INNER JOIN t_user u ON o.user_id = u.id
GROUP BY u.region
ORDER BY total_amount DESC;
