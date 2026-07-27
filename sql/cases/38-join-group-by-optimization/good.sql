-- good.sql: 先聚合后 JOIN（小结果集驱动）
--
-- 原理:
--   1. 子查询先在 t_order 表内按 user_id 聚合，100 万行 -> 1 万行
--      利用 idx_user_id 索引有序扫描，避免临时表（GROUP BY 走索引）
--   2. 聚合结果(1万行) JOIN t_user(1万行) 按 region 做二次聚合
--      1 万行 JOIN 1 万行 -> 1 万行中间结果，再 GROUP BY region -> 10 行
--   3. 最终临时表只处理 1 万行级别数据，内存即可容纳
--
--   bad 方案: 100 万行 JOIN -> 100 万行临时表 GROUP BY
--   good 方案: 100 万行索引扫描聚合 -> 1万行 JOIN -> 1万行临时表 GROUP BY
SELECT
    u.region                  AS region,
    SUM(ot.order_count)       AS order_count,
    SUM(ot.total_amount)      AS total_amount
FROM (
    SELECT
        user_id,
        COUNT(*)              AS order_count,
        SUM(amount)           AS total_amount
    FROM t_order
    GROUP BY user_id
) ot
INNER JOIN t_user u ON ot.user_id = u.id
GROUP BY u.region
ORDER BY total_amount DESC;
