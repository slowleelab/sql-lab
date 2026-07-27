-- ============================================================
-- 案例五十三: 读写分离架构
-- 场景: 主库写压力大，读流量分流到从库。用两张同构表模拟主库与从库
--        t_order_master 模拟主库表，t_order_replica 模拟从库表（结构相同）
-- ============================================================

-- 主库表: 承载写入 + 部分强一致读
DROP TABLE IF EXISTS t_order_master;
CREATE TABLE t_order_master (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单主表（模拟主库）';

-- 从库表: 结构与主库完全相同，模拟通过主从复制同步的从库读节点
DROP TABLE IF EXISTS t_order_replica;
CREATE TABLE t_order_replica (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单从表（模拟从库读节点）';
