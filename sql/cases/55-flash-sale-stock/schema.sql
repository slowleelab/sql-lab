-- ============================================================
-- 案例二十五: 秒杀场景库存扣减
-- 场景: 高并发扣减商品库存，防止超卖
-- ============================================================

DROP TABLE IF EXISTS t_stock;
CREATE TABLE t_stock (
    id           INT      NOT NULL AUTO_INCREMENT,
    product_id   INT      NOT NULL              COMMENT '商品ID',
    stock        INT      NOT NULL DEFAULT 0    COMMENT '库存数量',
    version      INT      NOT NULL DEFAULT 0    COMMENT '乐观锁版本号',
    updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_product (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品库存表';
