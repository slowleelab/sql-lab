-- bad.sql: 长事务阻塞 GC

-- 1. 查看当前 GC 配置
SHOW VARIABLES LIKE '%gc%';
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_life_time';
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_safe_point';

-- 2. 模拟长事务（在另一个会话保持 BEGIN 不提交）
-- 在 Session A: BEGIN; SELECT * FROM t_gc_test WHERE id = 1;

-- 3. 在主会话做大量 DELETE
DELETE FROM t_gc_test WHERE status = 0;
-- 但这些旧版本无法被 GC 回收，因为 Safe Point 被长事务阻塞

-- 4. 查看当前事务
SELECT * FROM information_schema.cluster_processlist WHERE command != 'Sleep' AND time > 10;

-- 5. 查看锁视图
SELECT * FROM information_schema.data_lock_waits;
