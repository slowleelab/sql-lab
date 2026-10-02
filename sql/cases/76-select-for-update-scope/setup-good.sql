-- setup-good.sql: 给 category 字段加索引，使 FOR UPDATE 走索引定位行锁
ALTER TABLE t_product ADD KEY idx_category (category);
