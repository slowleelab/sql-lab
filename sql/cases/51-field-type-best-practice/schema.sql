-- ============================================================
-- 案例八十: 字段类型与长度选择最佳实践
-- 场景: 同一份业务数据（订单记录），bad 表类型随意选择，good 表精心选择。
--       bad 表: id BIGINT、status VARCHAR(20)、gender VARCHAR(10)、
--               phone VARCHAR(50)、amount FLOAT、remark VARCHAR(1000)、
--               is_deleted VARCHAR(5)
--       good 表: id INT UNSIGNED、status TINYINT UNSIGNED、gender CHAR(1)、
--               phone VARCHAR(20)、amount DECIMAL(10,2)、remark VARCHAR(500)、
--               is_deleted TINYINT(1)
-- 两表业务语义完全相同，仅字段类型不同，用于对比存储空间、索引大小、查询性能。
-- ============================================================

-- bad 表：类型选择随意，存在存储浪费、索引膨胀、精度问题
DROP TABLE IF EXISTS t_type_bad;
CREATE TABLE t_type_bad (
    id           BIGINT       NOT NULL AUTO_INCREMENT        COMMENT '主键(小表用BIGINT浪费)',
    order_no     VARCHAR(32)  NOT NULL                       COMMENT '订单号',
    user_id      BIGINT       NOT NULL                       COMMENT '用户ID',
    status       VARCHAR(20)  NOT NULL DEFAULT '待支付'      COMMENT '订单状态(中文字符串,应改TINYINT)',
    gender       VARCHAR(10)  NOT NULL DEFAULT '未知'        COMMENT '性别(中文字符串,应改CHAR(1)或TINYINT)',
    phone        VARCHAR(50)  NOT NULL DEFAULT ''            COMMENT '手机号(11位,VARCHAR(50)过大)',
    amount       FLOAT        NOT NULL DEFAULT 0             COMMENT '订单金额(FLOAT有精度问题)',
    remark       VARCHAR(1000) DEFAULT NULL                  COMMENT '备注(大部分为空,长度过大)',
    is_deleted   VARCHAR(5)   NOT NULL DEFAULT 'false'       COMMENT '逻辑删除(应改TINYINT(1))',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_phone  (phone),
    KEY idx_user   (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(类型选择随意-bad)';

-- good 表：类型精心选择，存储紧凑、索引小、无精度问题
DROP TABLE IF EXISTS t_type_good;
CREATE TABLE t_type_good (
    id           INT UNSIGNED NOT NULL AUTO_INCREMENT        COMMENT '主键(小表INT UNSIGNED足够)',
    order_no     VARCHAR(32)  NOT NULL                       COMMENT '订单号',
    user_id      BIGINT       NOT NULL                       COMMENT '用户ID',
    status       TINYINT UNSIGNED NOT NULL DEFAULT 0         COMMENT '订单状态(0待支付/1已支付/2已发货/3已完成/4已取消)',
    gender       CHAR(1)      NOT NULL DEFAULT 'U'           COMMENT '性别(M男/F女/U未知)',
    phone        VARCHAR(20)  NOT NULL DEFAULT ''            COMMENT '手机号(11位,VARCHAR(20)足够)',
    amount       DECIMAL(10,2) NOT NULL DEFAULT 0.00         COMMENT '订单金额(DECIMAL精确)',
    remark       VARCHAR(500) DEFAULT NULL                   COMMENT '备注(合理长度,空值不占行内空间)',
    is_deleted   TINYINT(1)   NOT NULL DEFAULT 0             COMMENT '逻辑删除(0未删/1已删)',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (id),
    KEY idx_status (status),
    KEY idx_phone  (phone),
    KEY idx_user   (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(类型精心选择-good)';

-- 注: 两表业务语义完全对应:
--   status:  '待支付'->0  '已支付'->1  '已发货'->2  '已完成'->3  '已取消'->4
--   gender:  '男'->'M'  '女'->'F'  '未知'->'U'
--   is_deleted: 'false'->0  'true'->1
--   amount/phone/remark/user_id 业务值相同，仅存储类型不同
