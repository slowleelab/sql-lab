-- 读写温和倾斜的表，用于演示 Region 分布和热点现象
-- 表设计要点:
--   1. id 为 BIGINT AUTO_INCREMENT 主键——连续递增 ID 天然导致 Region 写入热点（新 ID 落在最后一个 Region）
--   2. idx_ts 索引在 ts 列上——ts 倾斜写入时，索引 Region 也会成为热点
--   3. APPROXIMATE 信息帮助观察 Region 大小变化

DROP TABLE IF EXISTS t_region_test;
CREATE TABLE t_region_test (
    id    BIGINT   NOT NULL AUTO_INCREMENT,
    val   INT      NOT NULL DEFAULT 0,
    ts    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_ts (ts)
);
