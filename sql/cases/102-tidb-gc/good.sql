-- good.sql: GC 优化与长事务治理

-- 1. 调整 GC 配置
UPDATE mysql.tidb SET variable_value = '24h' WHERE variable_name = 'tikv_gc_life_time';

-- 2. 查看 GC 状态和 Safe Point
SELECT * FROM mysql.tidb WHERE variable_name IN ('tikv_gc_safe_point', 'tikv_gc_run_interval', 'tikv_gc_life_time');

-- 3. 设置事务超时，防止长事务
SET SESSION tidb_idle_transaction_timeout = 300;
SET SESSION max_execution_time = 10000;

-- 4. 查看 GC 历史
SELECT * FROM mysql.tidb WHERE variable_name LIKE 'tikv_gc%';

-- 5. 合理的事务设计：短事务 + 分批处理
-- 将大量 DELETE 拆分为小批次
DELETE FROM t_gc_test WHERE status = 1 LIMIT 1000;
-- 每批次提交后 GC 可推进
