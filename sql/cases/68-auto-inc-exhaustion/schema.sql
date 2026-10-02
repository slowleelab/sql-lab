-- ============================================================
-- 案例七十二: 自增主键耗尽与分布式 ID
-- 场景: 订单表用 INT 自增主键，运行 3 年后 ID 达到 21 亿上限
-- ============================================================

-- bad 表：使用 INT UNSIGNED 自增主键（上限 42 亿，INT 有符号 21 亿）
DROP TABLE IF EXISTS t_order_bad;
CREATE TABLE t_order_bad (
    id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '订单状态',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB AUTO_INCREMENT=4294967290 COMMENT='订单表（INT 即将耗尽）';

-- good 表：使用 BIGINT + 雪花 ID（应用层生成，64 位，可用 69 年）
DROP TABLE IF EXISTS t_order_good;
CREATE TABLE t_order_good (
    id           BIGINT        NOT NULL              COMMENT '雪花ID（应用层生成）',
    order_no     VARCHAR(32)   NOT NULL              COMMENT '订单号',
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '订单金额',
    status       TINYINT       NOT NULL DEFAULT 0    COMMENT '订单状态',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user (user_id)
) ENGINE=InnoDB COMMENT='订单表（雪花ID）';
