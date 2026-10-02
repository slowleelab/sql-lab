-- bad.sql: TiKV 行存上的聚合查询
-- 设置 TiKV 行存模式（不启用 MPP）
SET SESSION tidb_enforce_mpp = OFF;
SET SESSION tidb_allow_mpp = OFF;

-- OLAP 聚合查询：按 category + region 统计销售额和销量
EXPLAIN SELECT category, region, COUNT(*) AS orders, SUM(amount) AS total_amount, SUM(qty) AS total_qty, AVG(amount) AS avg_amount
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;

-- 查看表是否有 TiFlash 副本
SELECT * FROM information_schema.tiflash_replica WHERE table_schema = 'sql_treasure';
