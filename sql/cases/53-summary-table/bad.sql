-- 实时聚合：对 30 万行明细表做 GROUP BY DATE(created_at)
-- 虽然有 idx_created 索引，但 GROUP BY DATE(created_at) 需要函数转换
-- MySQL 需扫描大量行做聚合计算，大表实时聚合耗时严重
SELECT DATE(created_at) AS d,
       COUNT(*) AS cnt,
       SUM(amount) AS total
FROM t_order_report
WHERE created_at >= '2026-01-01'
GROUP BY DATE(created_at)
ORDER BY d;
