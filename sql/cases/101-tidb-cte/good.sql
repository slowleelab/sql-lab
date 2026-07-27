-- good.sql: 使用 CTE 和递归 CTE 优化

-- ============================================================
-- 场景1：WITH RECURSIVE 递归 CTE 查询整棵树
-- ============================================================
WITH RECURSIVE tree_path AS (
    SELECT id, parent_id, name, CAST(name AS CHAR(500)) AS path, 1 AS depth
    FROM t_tree WHERE parent_id IS NULL
    UNION ALL
    SELECT t.id, t.parent_id, t.name, CONCAT(tp.path, ' -> ', t.name), tp.depth + 1
    FROM t_tree t JOIN tree_path tp ON t.parent_id = tp.id
    WHERE tp.depth < 10
)
SELECT * FROM tree_path ORDER BY path;

-- ============================================================
-- 场景2：CTE 物化避免重复计算 AVG(val)
-- ============================================================
WITH avg_val AS (
    SELECT AVG(val) AS avg_v FROM t_cte_data
)
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val) * 2;
-- avg_v 只计算一次，CTE 被多次引用时 TiDB 会物化

-- ============================================================
-- TiDB 递归 CTE 相关参数
-- ============================================================
SHOW VARIABLES LIKE '%cte%';
SHOW VARIABLES LIKE 'tidb_max_chunk_size';

-- ============================================================
-- 临时表（TiDB 特有注意事项）
-- 临时表在 TiDB 中是会话级别的，但某些语法有限制
-- ============================================================

-- 创建临时表缓存高值数据（会话级别，连接断开后自动删除）
-- CREATE TEMPORARY TABLE temp_high_val AS
-- SELECT * FROM t_cte_data WHERE val > 8000;

-- 使用临时表做后续计算
-- SELECT COUNT(*) FROM temp_high_val;

-- 注意：TiDB 临时表不支持 ALTER TABLE、不支持外键、
-- 不支持在临时表上创建普通索引（仅支持主键）

-- ============================================================
-- EXPLAIN 查看执行计划
-- ============================================================
EXPLAIN WITH RECURSIVE tree_path AS (
    SELECT id, parent_id, name, CAST(name AS CHAR(500)) AS path, 1 AS depth
    FROM t_tree WHERE parent_id IS NULL
    UNION ALL
    SELECT t.id, t.parent_id, t.name, CONCAT(tp.path, ' -> ', t.name), tp.depth + 1
    FROM t_tree t JOIN tree_path tp ON t.parent_id = tp.id
    WHERE tp.depth < 10
)
SELECT * FROM tree_path ORDER BY path;

EXPLAIN WITH avg_val AS (
    SELECT AVG(val) AS avg_v FROM t_cte_data
)
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT avg_v FROM avg_val) * 2;
