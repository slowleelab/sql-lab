-- bad.sql: 不使用 Prepared Statement 导致每次重新优化

-- 1. 普通 SQL（每次优化器都要重新解析和优化）
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 100;
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 200;
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 300;
-- 三条 SQL 虽然模式相同，但每次都要完整走优化流程

-- 2. 检查 Plan Cache 状态
SHOW VARIABLES LIKE 'tidb_enable_prepared_plan_cache';
SHOW GLOBAL STATUS LIKE 'Plan_cache%';

-- 3. 高并发下不使用 Prepare 的后果
-- 每个连接都要独立优化 SQL，CPU 消耗高
SELECT @@tidb_enable_prepared_plan_cache;
