-- ============================================================
-- 案例六十: STRAIGHT_JOIN 强制驱动顺序
-- 场景: 三表 JOIN，优化器选错驱动表导致中间结果集爆炸，
--       用 STRAIGHT_JOIN 强制从 t_order 开始，先过滤 user_id
-- ============================================================

-- 订单表: 10 万行
DROP TABLE IF EXISTS t_order_sj;
CREATE TABLE t_order_sj (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '状态',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';

-- 订单项表: 30 万行
DROP TABLE IF EXISTS t_order_item_sj;
CREATE TABLE t_order_item_sj (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_id     BIGINT        NOT NULL              COMMENT '订单ID',
    product_id   BIGINT        NOT NULL              COMMENT '商品ID',
    quantity     INT           NOT NULL              COMMENT '数量',
    price        DECIMAL(10,2) NOT NULL              COMMENT '单价',
    PRIMARY KEY (id),
    KEY idx_order_id (order_id),
    KEY idx_product_id (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单项表';

-- 商品表: 1 万行
DROP TABLE IF EXISTS t_product_sj;
CREATE TABLE t_product_sj (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100) NOT NULL              COMMENT '商品名称',
    category     VARCHAR(20)  NOT NULL              COMMENT '分类',
    price        DECIMAL(10,2) NOT NULL             COMMENT '价格',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表';
