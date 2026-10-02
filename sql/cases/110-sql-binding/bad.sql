-- bad.sql: 统计信息偏差导致优化器选错执行计划

-- 1. 更新统计信息（模拟统计信息偏差场景）
--    注意：status=1 占 90%，优化器可能认为索引扫描代价高而选择全表扫描
ANALYZE TABLE t_spm_test;

-- 2. 查看实际的 status 分布
SELECT status,
       COUNT(*) AS cnt,
       CONCAT(ROUND(COUNT(*) / 300000 * 100, 2), '%') AS pct
FROM t_spm_test
GROUP BY status
ORDER BY status;

-- 3. 查询：按 status=1 + city='Beijing' 过滤，按 created_at 排序，取前 20 条
--    status=1 占 90%，优化器可能认为走 idx_status 回表代价过高，
--    转而选择全表扫描 + 排序（TableFullScan + Sort）
EXPLAIN SELECT * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;

-- 4. 实际执行（观察耗时）
SELECT SQL_NO_CACHE * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;

-- 5. 确认当前没有任何 Binding
SHOW GLOBAL BINDINGS;

-- 6. 查看优化器可选索引
SHOW INDEX FROM t_spm_test;
