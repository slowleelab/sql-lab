-- ============================================================
-- 案例五十八: HAVING 改 WHERE 提前过滤
-- 场景: 订单统计查询先 GROUP BY 再 HAVING 过滤 status，
--       导致分组了 100 万行才过滤。将 status 条件提前到 WHERE，
--       只分组 25 万行，大幅减少分组计算量。
-- ============================================================

DROP TABLE IF EXISTS t_order_having;
CREATE TABLE t_order_having (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '状态: 0待支付/1已支付/2已发货/3已完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
