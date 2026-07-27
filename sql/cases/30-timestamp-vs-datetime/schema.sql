-- ============================================================
-- 案例七十六: 时区与 TIMESTAMP vs DATETIME
-- 场景: 跨时区业务中，TIMESTAMP 存储 UTC 并按 session time_zone
--       自动转换，导致同一行数据在不同时区下读出不同的 created_at，
--       报表"今天的订单"按 UTC 切分时整整错位 8 小时。
--       DATETIME 原样存取，不受 session time_zone 影响，业务时间稳定。
-- ============================================================

-- bad 表：用 TIMESTAMP 存 created_at / updated_at
-- TIMESTAMP 内部以 UTC 1970-01-01 至今的秒数存储，读写时按当前
-- session time_zone 做双向转换 -> 同一行在不同时区读出值不同。
DROP TABLE IF EXISTS t_time_bad;
CREATE TABLE t_time_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间(TIMESTAMP, 存UTC, 读时按会话时区转换)',
    updated_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(TIMESTAMP)';

-- good 表：用 DATETIME 存 created_at / updated_at
-- DATETIME 原样存储 YYYY-MM-DD HH:MM:SS，不随 session time_zone 改变，
-- 业务时间在任何时区读出来都一致；需要时区转换时查询中显式 CONVERT_TZ。
DROP TABLE IF EXISTS t_time_good;
CREATE TABLE t_time_good (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间(DATETIME, 原样存储, 不随时区改变)',
    updated_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(DATETIME)';

-- 注: 两张表结构完全相同（id, user_id, amount, created_at, updated_at），
--     仅 created_at / updated_at 的类型不同，用于对比时区行为差异。
