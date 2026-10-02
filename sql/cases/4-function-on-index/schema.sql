-- ============================================================
-- 案例四: 函数操作致索引失效
-- 场景: 订单表 created_at 有索引，查询用 DATE() / DATE_FORMAT() 包裹列
-- ============================================================

DROP TABLE IF EXISTS t_order_func;
CREATE TABLE t_order_func (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
