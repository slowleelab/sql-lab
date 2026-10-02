-- ============================================================
-- 案例二十二: 多条件动态筛选索引设计
-- 场景: 电商商品搜索，category + status + price 范围组合筛选
-- bad 场景: 只有单列索引，优化器难以高效处理多条件
-- ============================================================

DROP TABLE IF EXISTS t_goods;
CREATE TABLE t_goods (
    id            INT            NOT NULL AUTO_INCREMENT,
    name          VARCHAR(100)   NOT NULL              COMMENT '商品名称',
    category_id   INT            NOT NULL              COMMENT '分类ID',
    brand_id      INT            NOT NULL              COMMENT '品牌ID',
    price         DECIMAL(10,2)  NOT NULL              COMMENT '价格',
    status        TINYINT        NOT NULL DEFAULT 1    COMMENT '1=在售 2=下架 3=缺货',
    sales         INT            NOT NULL DEFAULT 0    COMMENT '销量',
    created_at    DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_category (category_id),
    KEY idx_status (status),
    KEY idx_price (price)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表（仅单列索引，bad 场景）';
