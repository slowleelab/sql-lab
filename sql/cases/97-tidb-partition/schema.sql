-- ============================================================
-- 案例九十七: TiDB 分区表优化
-- 场景: RANGE 分区（按年）和 HASH 分区两张对照表
-- ============================================================

-- RANGE 分区表：按订单日期年份分区
DROP TABLE IF EXISTS t_order_range;
CREATE TABLE t_order_range (
    id         BIGINT        NOT NULL AUTO_INCREMENT,
    user_id    BIGINT        NOT NULL              COMMENT '用户ID',
    amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '订单金额',
    order_date DATE          NOT NULL              COMMENT '订单日期',
    PRIMARY KEY (id, order_date),
    KEY idx_user_id (user_id),
    KEY idx_order_date (order_date)
) PARTITION BY RANGE (YEAR(order_date)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION p2027 VALUES LESS THAN (2028),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);

-- HASH 分区表：按用户 ID 哈希分区
DROP TABLE IF EXISTS t_order_hash;
CREATE TABLE t_order_hash (
    id         BIGINT        NOT NULL AUTO_INCREMENT,
    user_id    BIGINT        NOT NULL              COMMENT '用户ID',
    amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '订单金额',
    order_date DATE          NOT NULL              COMMENT '订单日期',
    PRIMARY KEY (id, user_id),
    KEY idx_user_id (user_id),
    KEY idx_order_date (order_date)
) PARTITION BY HASH (user_id) PARTITIONS 8;
