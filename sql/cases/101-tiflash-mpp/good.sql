-- good.sql: 创建 TiFlash 副本 + MPP 执行

-- 1. 创建 TiFlash 副本（需要在集群有 TiFlash 节点的前提下）
-- ALTER TABLE t_sales SET TIFLASH REPLICA 1;
-- 等待副本同步完成
-- SELECT * FROM information_schema.tiflash_replica WHERE table_schema = 'sql_treasure' AND available = 1;

-- 2. 启用 MPP 模式
SET SESSION tidb_enforce_mpp = ON;
SET SESSION tidb_allow_mpp = ON;

-- 3. 同样查询走 MPP + TiFlash
EXPLAIN SELECT category, region, COUNT(*) AS orders, SUM(amount) AS total_amount, SUM(qty) AS total_qty, AVG(amount) AS avg_amount
FROM t_sales
WHERE sale_date BETWEEN '2026-01-01' AND '2026-06-30'
GROUP BY category, region
ORDER BY total_amount DESC;

-- 4. 查看 MPP 相关设置
SHOW VARIABLES LIKE '%mpp%';
SHOW VARIABLES LIKE '%tiflash%';
