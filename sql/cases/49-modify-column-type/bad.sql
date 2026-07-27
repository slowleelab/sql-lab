-- bad.sql: 不指定 ALGORITHM 和 LOCK，让 MySQL 自行选择
-- 5.7 中修改列类型（VARCHAR(50) -> VARCHAR(20)）属于 rebuild 操作
-- 如果不显式指定 LOCK=NONE，MySQL 可能选择 LOCK=SHARED 甚至 COPY
-- LOCK=SHARED 期间: 允许读但阻塞所有写操作（INSERT/UPDATE/DELETE 排队）
-- 100 万行重建期间，业务写入完全停滞
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '手机号';
