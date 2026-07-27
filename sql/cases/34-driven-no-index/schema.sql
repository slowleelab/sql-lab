-- ============================================================
-- 案例十六: 被驱动表无索引的灾难
-- 场景: JOIN 时被驱动表的 JOIN 列 (order_id) 无索引 -> BNL/Hash Join
-- ============================================================

-- 订单主表: 10 万行
DROP TABLE IF EXISTS t_order_main;
CREATE TABLE t_order_main (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    PRIMARY KEY (id),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单主表';

-- 订单明细表: 30 万行，order_id 故意不加索引
DROP TABLE IF EXISTS t_order_item;
CREATE TABLE t_order_item (
    id            BIGINT       NOT NULL AUTO_INCREMENT,
    order_id      BIGINT       NOT NULL              COMMENT '订单ID',
    product_name  VARCHAR(50)  NOT NULL              COMMENT '商品名',
    qty           INT          NOT NULL              COMMENT '数量',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单明细表';
