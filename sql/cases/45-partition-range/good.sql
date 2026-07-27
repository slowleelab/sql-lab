-- good.sql: 分区表查询某月数据（分区裁剪）
--
-- 原理:
--   1. 分区表 t_partition_log 按 created_at 月度 RANGE 分区
--   2. 查询 created_at BETWEEN '2024-01-01' AND '2024-01-31'
--      优化器执行分区裁剪(pruning)，只访问 p202401 分区
--   3. EXPLAIN 的 partitions 列显示 p202401，而非全部 12 个分区
--   4. 扫描范围从 96 万行降到 8 万行，索引也更紧凑
--
--   前提: 先执行 setup-good.sql 创建分区表并迁移数据
SELECT
    id, user_id, log_level, message, created_at
FROM t_partition_log
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-01-31 23:59:59'
ORDER BY created_at DESC
LIMIT 100;
