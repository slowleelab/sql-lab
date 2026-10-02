-- ============================================================
-- 案例五十九: LIMIT 1 优化 EXISTS 子查询
-- 场景: 检查用户是否有未支付订单，用 COUNT(*) > 0 对每个用户
--       都 COUNT 全部匹配行，改写为 EXISTS + LIMIT 1 短路返回
-- ============================================================

-- 用户表: 10 万行
DROP TABLE IF EXISTS t_user_exists;
CREATE TABLE t_user_exists (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    username     VARCHAR(50)  NOT NULL              COMMENT '用户名',
    phone        VARCHAR(11)  NOT NULL              COMMENT '手机号',
    email        VARCHAR(100) NOT NULL              COMMENT '邮箱',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 订单表: 100 万行
DROP TABLE IF EXISTS t_order_exists;
CREATE TABLE t_order_exists (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '状态: 0未支付/1已支付/2已发货/3已完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_status (user_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
