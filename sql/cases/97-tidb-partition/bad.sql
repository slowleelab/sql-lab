-- ============================================================
-- bad.sql: 分区裁剪未生效或效率低下的查询
-- ============================================================

-- 1. 查询某年数据但未利用分区裁剪（使用函数包裹分区键）
--    注意：YEAR() 在 TiDB 中通常可以做分区裁剪，
--    但范围条件 BETWEEN 更直接，我们先看原始写法
EXPLAIN
SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01';

-- 2. 检查 Dynamic Pruning 是否启用
SHOW VARIABLES LIKE 'tidb_partition_prune_mode';

-- 3. HASH 分区表：查询单个 user_id 无法裁剪分区
--    HASH 分区按 user_id 分布，单值查询理论上只命中一个分区
--    但在 static pruning 模式下可能无法精确裁剪
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;

-- 4. HASH 分区表：跨用户范围查询，所有分区都要扫描
EXPLAIN SELECT COUNT(*), SUM(amount)
FROM t_order_hash
WHERE user_id BETWEEN 10000 AND 20000;

-- 5. 查看分区信息和行数分布
SELECT PARTITION_NAME, TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_range';
