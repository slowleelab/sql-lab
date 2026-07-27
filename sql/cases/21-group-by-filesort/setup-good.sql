-- setup-good.sql: 优化方案的前置 DDL -- 给 city 字段加索引
ALTER TABLE t_order_stat ADD KEY idx_city (city);
