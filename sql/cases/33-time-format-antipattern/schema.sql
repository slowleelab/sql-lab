-- ============================================================
-- 案例七十八: 时间格式使用错误与最佳实践
-- 场景: 用 VARCHAR 存时间字符串，查询时陷入三类反模式:
--       1) 字符串范围比较语义可能不正确（字典序而非时间序）
--       2) DATE_FORMAT 函数包裹字段致索引失效（全表扫描）
--       3) BETWEEN 字符串日期的边界陷阱（漏掉当天数据）
--       正解: 用 DATETIME 类型 + 闭开区间 [start, end) 范围查询。
-- ============================================================

-- bad 表：用 VARCHAR(20) 存时间字符串（如 '2026-07-01 08:00:00'）
-- 反模式根源:
--   - VARCHAR 存时间无法使用时间函数做正确的时间运算与比较
--   - 范围比较走的是字符串字典序，格式不统一时语义可能错误
--   - DATE_FORMAT / YEAR / MONTH 等函数作用于 VARCHAR 列无法走索引
--   - 无法利用 MySQL 对时间类型的存储与索引优化
DROP TABLE IF EXISTS t_time_bad;
CREATE TABLE t_time_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   VARCHAR(20)   NOT NULL              COMMENT '创建时间(VARCHAR存时间字符串, 如 2026-07-01 08:00:00)',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(VARCHAR存时间, 反模式)';

-- good 表：用 DATETIME 存时间
-- 优势:
--   - 原生时间类型，支持时间函数和正确的范围比较
--   - 范围查询走 B+ 树索引范围扫描，语义与性能均正确
--   - 不需要函数包裹字段，索引可正常使用
DROP TABLE IF EXISTS t_time_good;
CREATE TABLE t_time_good (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    amount       DECIMAL(10,2) NOT NULL              COMMENT '金额',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间(DATETIME, 原生时间类型)',
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表(DATETIME存时间, 正解)';

-- 注: 两张表结构完全相同（id, user_id, amount, created_at），仅 created_at 的类型不同
--     (bad=VARCHAR(20), good=DATETIME)，用于对比时间格式选择的性能与正确性差异。
