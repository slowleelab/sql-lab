-- Online DDL 方式：ALGORITHM=INPLACE, LOCK=NONE
-- INPLACE 模式在存储引擎内部完成索引构建，不创建临时表
-- LOCK=NONE 允许 DDL 期间并发执行 DML（INSERT/UPDATE/DELETE 不阻塞）
-- 8.0 中部分操作可进一步用 ALGORITHM=INSTANT（元数据级变更，瞬间完成）
-- 注意：加索引不支持 INSTANT，但 INPLACE+LOCK=NONE 已是最佳实践
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id), ALGORITHM=INPLACE, LOCK=NONE;
