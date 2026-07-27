-- setup-good.sql: 在 status 列创建直方图（8.0 专有特性）
-- 直方图精确记录列值分布，让优化器感知 status=0 占 99% 的数据倾斜
-- 注: 直方图仅 8.0 支持；创建后需确认优化器能据此选对索引
ANALYZE TABLE t_task UPDATE HISTOGRAM ON status WITH 100 BUCKETS;
