-- ============================================================
-- good.sql: 利用 Dynamic Pruning 实现分区裁剪
-- ============================================================

-- 1. 确认 dynamic pruning 模式（TiDB v6.x+ 默认）
SET SESSION tidb_partition_prune_mode = 'dynamic';

-- 2. RANGE 分区裁剪：只访问对应分区
--    使用 BETWEEN 明确范围，优化器能精确裁剪到 2025 年的分区
EXPLAIN
SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';

-- 3. 查看 EXPLAIN 中的 access object 列
--    Dynamic Pruning 下，分区信息显示在算子级别
--    例如: partition:p2025 表示只访问 p2025 分区
EXPLAIN
SELECT * FROM t_order_range
WHERE order_date = '2025-06-15';

-- 4. 跨分区查询：裁剪后只访问相关分区
EXPLAIN
SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date BETWEEN '2025-06-01' AND '2025-08-31';

-- 5. 查看各分区数据分布
SELECT PARTITION_NAME, TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_range'
ORDER BY PARTITION_ORDINAL_POSITION;

-- 6. HASH 分区单值查询：确认是否命中单个分区
EXPLAIN SELECT * FROM t_order_hash WHERE user_id = 12345;

-- 7. 对比 Static Pruning（旧模式）
SET SESSION tidb_partition_prune_mode = 'static';
EXPLAIN
SELECT COUNT(*), SUM(amount)
FROM t_order_range
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31';

-- 8. 恢复 Dynamic Pruning
SET SESSION tidb_partition_prune_mode = 'dynamic';

-- 9. TiDB 独有的分区分布查看（表 Region 分布）
SHOW TABLE t_order_range REGIONS;

-- 10. 确认分区表在 TiKV 中的 Region 分布
SELECT
    p.PARTITION_NAME,
    p.TABLE_ROWS,
    COUNT(r.REGION_ID) AS region_count
FROM information_schema.PARTITIONS p
LEFT JOIN information_schema.TIKV_REGION_PEERS r
    ON r.TABLE_ID = (
        SELECT TIDB_TABLE_ID FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_range'
    )
WHERE p.TABLE_SCHEMA = DATABASE() AND p.TABLE_NAME = 't_order_range'
GROUP BY p.PARTITION_NAME, p.TABLE_ROWS;
