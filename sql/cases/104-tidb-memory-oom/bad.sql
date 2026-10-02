-- bad.sql: 可能导致 OOM 的查询

-- 1. 查看当前内存限额
SHOW VARIABLES LIKE '%mem%';
SHOW VARIABLES LIKE '%oom%';

-- 2. 故意设置很低的内存限额来模拟 OOM
SET SESSION tidb_mem_quota_query = 104857600; -- 100MB

-- 3. 大 GROUP BY 聚合（HashAgg 内存超限）
-- 50000 个 group，每个 group 需要内存暂存
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;

-- 4. 查看 OOM 相关记录
SHOW VARIABLES LIKE 'tidb_enable_tmp_storage_on_oom';
