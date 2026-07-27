-- good.sql: 显式指定 ALGORITHM=INPLACE, LOCK=NONE
-- INPLACE 在存储引擎内部完成重建，不创建临时表
-- LOCK=NONE 允许 DDL 期间并发执行 DML（读写均不阻塞）
-- 原理: row log 记录 DDL 期间的 DML 变更，完成后回放合并
-- 注意: 如果指定了 LOCK=NONE 但操作不支持，MySQL 会直接报错而非静默退化
--       这样可以避免"以为不锁表实际锁了"的生产事故
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '手机号', ALGORITHM=INPLACE, LOCK=NONE;
