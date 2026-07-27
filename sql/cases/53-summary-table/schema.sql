-- ============================================================
-- 案例二十三: 报表统计汇总表
-- 场景: 实时统计每天订单数和金额，大表 GROUP BY 很慢
-- 优化: 用汇总表 t_daily_summary 预计算每日数据
-- ============================================================

-- 明细表: 30 万行订单
DROP TABLE IF EXISTS t_order_report;
CREATE TABLE t_order_report (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '0待付/1已付/2发货/3完成',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '下单时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单明细表';

-- 汇总表: 按天预聚合
DROP TABLE IF EXISTS t_daily_summary;
CREATE TABLE t_daily_summary (
    stat_date     DATE           NOT NULL             COMMENT '统计日期',
    order_count   INT            NOT NULL DEFAULT 0   COMMENT '订单数',
    total_amount  DECIMAL(15,2)  NOT NULL DEFAULT 0   COMMENT '总金额',
    PRIMARY KEY (stat_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='每日订单汇总表';
