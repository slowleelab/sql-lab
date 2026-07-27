-- ============================================================
-- 案例七十四: 慢查询排查方法论
-- 场景: 生产 CPU 飙升但不知哪条 SQL 导致，演示完整诊断链路
--       slow log -> pt-query-digest -> performance_schema -> EXPLAIN ANALYZE
-- ============================================================

-- 诊断演示表：模拟生产订单表
-- 故意"设计缺陷"：只有 idx_user，缺少 (status, created_at) 和 (user_id, amount)
-- 让下面三类查询在生产中变慢，等待 DBA 通过慢查询排查链路定位
DROP TABLE IF EXISTS t_order_diag;
CREATE TABLE t_order_diag (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '状态: 0待付 1已付 2发货 3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表（用于慢查询诊断演示）';
