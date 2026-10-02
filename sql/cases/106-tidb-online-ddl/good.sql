-- good.sql: TiDB DDL 最佳实践

-- 1. 查看 DDL 进度和历史
ADMIN SHOW DDL JOBS 20;
ADMIN SHOW DDL JOB QUERIES;

-- 2. 设置 DDL 参数优化回填速度
SET GLOBAL tidb_ddl_reorg_worker_cnt = 4;
SET GLOBAL tidb_ddl_reorg_batch_size = 256;

-- 3. 添加索引（TiDB 默认 Online，不阻塞读写）
ALTER TABLE t_ddl_test ADD INDEX idx_age (age);

-- 4. 添加列（INSTANT 模式，秒级完成）
ALTER TABLE t_ddl_test ADD COLUMN phone VARCHAR(20) DEFAULT NULL;

-- 5. 修改列类型前评估影响
-- 使用 SHOW STATS_HEALTHY 检查表是否需要 ANALYZE
-- 避免在业务高峰期执行 DROP COLUMN / MODIFY COLUMN
SHOW STATS_HEALTHY WHERE table_name = 't_ddl_test';

-- 6. 暂停和恢复 DDL 任务
-- ADMIN PAUSE DDL JOBS job_id;
-- ADMIN RESUME DDL JOBS job_id;

-- 7. 查看 TiDB DDL 与 MySQL DDL 的差异
-- TiDB：无需 ALGORITHM/LOCK 子句（即使写了也被忽略）
-- TiDB：state transition 协议（absent -> delete only -> write only -> write reorganization -> public）
