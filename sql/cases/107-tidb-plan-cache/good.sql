-- good.sql: 使用 Prepared Statement 启用 Plan Cache

-- 1. 确保 Plan Cache 已启用
SET GLOBAL tidb_enable_prepared_plan_cache = ON;
SHOW VARIABLES LIKE 'tidb_enable_prepared_plan_cache';

-- 2. 设置 Plan Cache 容量
SET GLOBAL tidb_prepared_plan_cache_size = 100;
SHOW VARIABLES LIKE 'tidb_prepared_plan_cache%';

-- 3. 使用 Prepared Statement
PREPARE stmt FROM 'SELECT id, name, score FROM t_plan_cache WHERE user_id = ?';
SET @uid = 100;
EXECUTE stmt USING @uid;
SET @uid = 200;
EXECUTE stmt USING @uid;
SET @uid = 300;
EXECUTE stmt USING @uid;
DEALLOCATE PREPARE stmt;

-- 4. 查看 Plan Cache 命中统计
SHOW GLOBAL STATUS LIKE 'Plan_cache%';

-- 5. 查看当前缓存的计划
SELECT * FROM information_schema.cluster_plan_cache;

-- 6. EXPLAIN 显示 Plan Cache 使用情况
EXPLAIN FORMAT=plan_cache SELECT id, name, score FROM t_plan_cache WHERE user_id = ?;

-- 7. Plan Cache 的限制
-- 注意：以下查询无法使用 Plan Cache
-- - ORDER BY/GROUP BY 中有变量表达式
-- - LIMIT 使用了变量
-- - 包含子查询的语句
