-- bad.sql: 诊断 Region 热点

-- 1. 查看当前表的 Region 分布
--    注意观察每个 Region 的 START_KEY / END_KEY 范围和 Leader 分布
SHOW TABLE t_region_test REGIONS;

-- 2. 查看数据倾斜情况
--    热点值 '2026-07-28 12:00:00' 约有 15 万行（占 50%）
SELECT ts, COUNT(*) AS cnt
FROM t_region_test
GROUP BY ts
ORDER BY cnt DESC
LIMIT 10;

-- 3. 大量写入集中在同一个 ts 值，触发 Hot Region
--    新插入 5 万行全部使用热点 ts 值
--    所有新行的 idx_ts 索引键集中在同一 Region，导致该 Region 写入压力剧增
INSERT INTO t_region_test (val, ts)
SELECT val, '2026-07-28 12:00:00'
FROM t_region_test
LIMIT 50000;

-- 4. 再次查看 Region 分布
--    预期：某个 Region 的 approximate_size 明显大于其他 Region
--    且该 Region 的 Leader 所在 TiKV 节点可能 CPU 飙高
SHOW TABLE t_region_test REGIONS;

-- 5. 查看 TiKV 热点调度状态（概念说明，需连接 PD 执行）
-- SELECT region_id, hot_degree, flow_bytes
-- FROM information_schema.tikv_region_status
-- WHERE is_index = 0
-- ORDER BY flow_bytes DESC LIMIT 10;

-- 6. 查看热点 Region 调度配置
-- SHOW CONFIG WHERE type = 'pd' AND name LIKE '%hot%';

-- 7. 查看当前表的总 Region 数量和预估行数
SELECT
    TABLE_NAME,
    TABLE_ROWS,
    AVG_ROW_LENGTH,
    DATA_LENGTH,
    INDEX_LENGTH
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME = 't_region_test';
