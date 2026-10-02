-- ============================================================
-- 案例十一: COUNT(*) 慢查询优化
-- 场景: 大表 COUNT(*) 慢，通过汇总表预计算
-- ============================================================

-- 订单大表: 50 万行
DROP TABLE IF EXISTS t_order_count;
CREATE TABLE t_order_count (
    id           BIGINT      NOT NULL AUTO_INCREMENT,
    user_id      BIGINT      NOT NULL              COMMENT '用户ID',
    status       TINYINT     NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';

-- 汇总表: 按天预聚合订单数
DROP TABLE IF EXISTS t_order_daily_stats;
CREATE TABLE t_order_daily_stats (
    stat_date    DATE        NOT NULL              COMMENT '统计日期',
    order_count  INT         NOT NULL DEFAULT 0    COMMENT '当日订单数',
    PRIMARY KEY (stat_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单每日汇总表';
