-- ============================================================
-- 案例二十九: 乐观锁与悲观锁对比
-- 场景: 库存扣减，悲观锁 SELECT FOR UPDATE vs 乐观锁 version 号
-- ============================================================

DROP TABLE IF EXISTS t_stock_lock;
CREATE TABLE t_stock_lock (
    id          BIGINT   NOT NULL AUTO_INCREMENT,
    product_id  BIGINT   NOT NULL              COMMENT '商品ID',
    stock       INT      NOT NULL DEFAULT 0    COMMENT '库存数量',
    version     INT      NOT NULL DEFAULT 0    COMMENT '乐观锁版本号',
    updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_product (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='库存表（锁策略对比）';
