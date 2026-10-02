-- ============================================================
-- 案例八: 覆盖索引避免回表
-- 场景: 商品列表页只需要展示分类、名称、价格，不需要详情字段
-- ============================================================

DROP TABLE IF EXISTS t_product;
CREATE TABLE t_product (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100)  NOT NULL              COMMENT '商品名',
    category_id  INT           NOT NULL              COMMENT '分类ID',
    price        DECIMAL(10,2) NOT NULL              COMMENT '价格',
    stock        INT           NOT NULL DEFAULT 0    COMMENT '库存',
    description  TEXT          DEFAULT NULL           COMMENT '商品详情(长文本)',
    status       TINYINT       NOT NULL DEFAULT 1    COMMENT '1上架/0下架',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category_price (category_id, price),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表';
