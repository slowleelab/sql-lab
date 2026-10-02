-- good.sql: MySQL 8.0 INSTANT 算法加列（秒级完成）
-- ALGORITHM=INSTANT 只修改数据字典中的元数据，不触碰表数据
-- 新列的默认值记录在元数据中，查询时动态返回，无需逐行填充
-- 无论表有多少行，执行时间都是毫秒级
-- 注意: INSTANT 是 8.0.12+ 的特性，5.7 不支持
ALTER TABLE t_order ADD COLUMN source VARCHAR(20) NOT NULL DEFAULT 'web' COMMENT '订单来源', ALGORITHM=INSTANT;
