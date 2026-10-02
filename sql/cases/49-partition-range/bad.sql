-- bad.sql: 普通表查询某月数据（全表扫描）
--
-- 原理:
--   1. 普通表 t_partition_log 无分区，96 万行数据存储在单一表空间
--   2. 查询 created_at BETWEEN '2024-01-01' AND '2024-01-31'
--      虽然走 idx_created 索引，但索引跨越全部 96 万行
--   3. 无分区裁剪：优化器无法排除其他月份数据的索引范围
--   4. EXPLAIN 的 partitions 列为 NULL（无分区）
--
--   对比分区表: 分区裁剪后只扫 p202401 一个分区(8万行)
SELECT
    id, user_id, log_level, message, created_at
FROM t_partition_log
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-01-31 23:59:59'
ORDER BY created_at DESC
LIMIT 100;
