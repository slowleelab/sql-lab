-- ============================================================
-- 案例五十四: JSON 字段使用模式
-- 场景: 商品属性 attrs 用 JSON 存储，按 JSON 内部字段（如 color）查询
--        直接 JSON_EXTRACT 查询全表扫描，8.0 用虚拟列 + 索引优化
-- ============================================================

DROP TABLE IF EXISTS t_product_json;
CREATE TABLE t_product_json (
    id            BIGINT       NOT NULL AUTO_INCREMENT,
    product_name  VARCHAR(100) NOT NULL              COMMENT '商品名称',
    attrs         JSON         NOT NULL              COMMENT '商品属性 {"color":"red","size":"L","brand":"Nike"}',
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表(JSON属性)';
