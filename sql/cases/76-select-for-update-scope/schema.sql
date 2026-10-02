-- ============================================================
-- 案例二十八: SELECT FOR UPDATE 锁范围
-- 场景: WHERE 条件无索引导致 FOR UPDATE 锁升级为表锁
-- ============================================================

DROP TABLE IF EXISTS t_product;
CREATE TABLE t_product (
    id            BIGINT        NOT NULL AUTO_INCREMENT,
    product_name  VARCHAR(100)  NOT NULL              COMMENT '商品名称',
    stock         INT           NOT NULL DEFAULT 0    COMMENT '库存数量',
    category      VARCHAR(20)   NOT NULL              COMMENT '商品分类（无索引）',
    price         DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '价格',
    updated_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表（锁范围演示）';
