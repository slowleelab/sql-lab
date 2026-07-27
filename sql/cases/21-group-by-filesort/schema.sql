-- ============================================================
-- 案例十二: GROUP BY filesort 优化
-- 场景: 按分类统计商品数量和平均价格，GROUP BY 字段无索引
-- ============================================================

DROP TABLE IF EXISTS t_order_stat;
CREATE TABLE t_order_stat (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    city         VARCHAR(20)   NOT NULL              COMMENT '城市',
    product_cate VARCHAR(20)   NOT NULL              COMMENT '商品分类',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    order_date   DATE          NOT NULL              COMMENT '下单日期',
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单统计表';
