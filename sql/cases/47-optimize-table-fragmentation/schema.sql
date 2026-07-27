-- ============================================================
-- 案例五十二: OPTIMIZE TABLE 碎片整理
-- 场景: 大量 DELETE 后表碎片化，空间未释放，查询效率下降
-- ============================================================

DROP TABLE IF EXISTS t_fragment_order;
CREATE TABLE t_fragment_order (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成/4已取消',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    KEY idx_status_created (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='碎片测试订单表';
