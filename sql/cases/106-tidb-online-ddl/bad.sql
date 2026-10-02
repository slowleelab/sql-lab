-- bad.sql: DDL 常见误区

-- 1. 添加索引时未关注进度（可能导致业务感知延迟）
-- 查看当前 DDL 任务
ADMIN SHOW DDL JOBS;

-- 2. 显示指定 ALGORITHM（TiDB 忽略此语法但保留兼容）
ALTER TABLE t_ddl_test ADD INDEX idx_name (name) ALGORITHM=INPLACE;

-- 3. 修改列类型导致隐式重写
ALTER TABLE t_ddl_test MODIFY COLUMN age BIGINT;

-- 4. 高并发写入时执行 DDL
-- 查看 DDL 是否阻塞写入
SHOW VARIABLES LIKE 'tidb_ddl_reorg_worker_cnt';
SHOW VARIABLES LIKE 'tidb_ddl_reorg_batch_size';

-- 5. 查看慢 DDL 语句
ADMIN SHOW DDL JOBS WHERE state = 'running';
