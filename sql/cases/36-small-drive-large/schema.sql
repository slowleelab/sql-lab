-- ============================================================
-- 案例十五: JOIN 小表驱动大表
-- 场景: 查询某活动涉及的订单明细，活动表(小) JOIN 订单表(大)
-- ============================================================

-- 大表: 20 万订单
DROP TABLE IF EXISTS t_order_big;
CREATE TABLE t_order_big (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL,
    order_no     VARCHAR(32)   NOT NULL,
    amount       DECIMAL(10,2) NOT NULL,
    status       TINYINT       NOT NULL DEFAULT 0,
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_order_no (order_no),
    KEY idx_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单大表';

-- 小表: 5000 条活动关联记录
DROP TABLE IF EXISTS t_promotion_ref;
CREATE TABLE t_promotion_ref (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    promotion_id INT          NOT NULL              COMMENT '活动ID',
    order_no     VARCHAR(32)  NOT NULL              COMMENT '关联订单号',
    discount     DECIMAL(8,2) NOT NULL              COMMENT '折扣金额',
    PRIMARY KEY (id),
    KEY idx_promotion (promotion_id),
    KEY idx_order_no (order_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='活动关联表';
