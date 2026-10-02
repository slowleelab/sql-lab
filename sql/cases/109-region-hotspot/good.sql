-- good.sql: Region 热点调度与 Split 策略

-- ============================================================
-- 方案 1: 手动 SPLIT TABLE — 将表预分裂为多个 Region
-- ============================================================

-- 将 t_region_test 按主键范围预分裂为 8 个 Region
-- BETWEEN (0) AND (MAXVALUE) 表示按主键范围均匀切分
-- 注意：此操作要求表已有数据，执行后数据会重新分布
SPLIT TABLE t_region_test BETWEEN (0) AND (MAXVALUE) REGIONS 8;

-- 查看 Split 后的 Region 分布
-- 预期：START_KEY 和 END_KEY 被均匀切分为 8 个范围
SHOW TABLE t_region_test REGIONS;

-- ============================================================
-- 方案 2: SCATTER — 打散 Region 的 Leader 和 Peer 分布
-- ============================================================

-- 打散 Region，让 Leader 和 Peer 均匀分布在不同 TiKV 节点上
-- 注意：SCATTER 是异步操作，需要等待调度完成
ALTER TABLE t_region_test SCATTER;

-- 等待几秒后再次查看，确认 Region 已重新分布
SHOW TABLE t_region_test REGIONS;

-- ============================================================
-- 方案 3: 查看 PD 热点调度配置
-- ============================================================

-- PD 热点调度器相关参数（概念说明，需连接 PD 执行）
-- SHOW CONFIG WHERE type = 'pd' AND name LIKE '%hot-region%';

-- 关键参数速查：
-- ----------------------------------------------------------
-- | 参数名                            | 默认值 | 说明                     |
-- |-----------------------------------|--------|--------------------------|
-- | hot-region-schedule-limit         | 4      | 同时调度的热点 Region 上限 |
-- | hot-region-cache-hits-threshold   | 3      | 识别为热点的命中阈值       |
-- | leader-schedule-limit             | 4      | 同时迁 Leader 的上限       |
-- | region-schedule-limit             | 2048   | 同时迁 Region 的上限       |
-- ----------------------------------------------------------

-- ============================================================
-- 方案 4: 使用 SPLIT TABLE 按索引值切分（针对 idx_ts 热点）
-- ============================================================

-- 如果热点集中在某个索引值范围，可以在建表时就预分配 Region
-- 以下为建表即带 SPLIT 的示例（仅作参考，不实际执行）
-- CREATE TABLE t_region_test_pre_split (
--     id    BIGINT   NOT NULL AUTO_INCREMENT,
--     val   INT      NOT NULL DEFAULT 0,
--     ts    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     PRIMARY KEY (id),
--     INDEX idx_ts (ts)
-- ) PARTITION BY RANGE (YEAR(ts)) (
--     PARTITION p2025 VALUES LESS THAN (2026),
--     PARTITION p2026 VALUES LESS THAN (2027),
--     PARTITION p2027 VALUES LESS THAN (2028)
-- );

-- ============================================================
-- 方案 5: 验证 Region 均衡性
-- ============================================================

-- 查看所有 Region 的状态（概念说明，需连接 PD 或 TiKV 执行）
-- SELECT
--     r.region_id,
--     r.approximate_size,
--     r.approximate_keys,
--     p.store_id,
--     p.is_leader
-- FROM information_schema.tikv_region_status r
-- JOIN information_schema.tikv_region_peers p
--   ON r.region_id = p.region_id
-- WHERE r.table_name = 't_region_test'
-- ORDER BY r.approximate_size DESC;

-- 确认表整体的 Region 分布已均衡
SELECT 'SPLIT + SCATTER 完成，请通过 SHOW TABLE t_region_test REGIONS 验证'
    AS operation_result;
