-- good.sql: OOM 防护与优化

-- 1. 启用临时磁盘溢出（默认已启用）
SET GLOBAL tidb_enable_tmp_storage_on_oom = ON;
SHOW VARIABLES LIKE 'tidb_enable_tmp_storage_on_oom';

-- 2. 合理设置内存限额
SET SESSION tidb_mem_quota_query = 1073741824; -- 1GB

-- 3. 监控内存使用（通过 EXPLAIN ANALYZE 查看各算子实际内存）
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;

-- 4. 查看 TiDB Server 全局内存使用
SELECT * FROM information_schema.cluster_processlist WHERE command = 'Query';

-- 5. 查看 OOM Action 日志
SHOW VARIABLES LIKE 'tidb_mem_oom_action';
-- LOG 只记录日志不中断，CANCEL 中断当前 SQL

-- 6. 针对高基数 GROUP BY 的分批策略
-- 如果 group 数过大，可先按条件分批聚合
SELECT group_id, COUNT(*), AVG(value), SUM(value)
FROM t_oom_test
WHERE group_id BETWEEN 1 AND 10000
GROUP BY group_id;
