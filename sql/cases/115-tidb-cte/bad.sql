-- bad.sql: 不使用 CTE 的递归和子查询写法

-- ============================================================
-- 场景1：自连接多层查询树形结构（SQL 冗长，层数固定）
-- ============================================================
SELECT t1.name AS l1, t2.name AS l2, t3.name AS l3
FROM t_tree t1
LEFT JOIN t_tree t2 ON t2.parent_id = t1.id
LEFT JOIN t_tree t3 ON t3.parent_id = t2.id
WHERE t1.parent_id IS NULL
LIMIT 20;

-- 若需要查 10 层，需要 10 次 LEFT JOIN —— SQL 极其冗长，且无法自适应任意深度

-- ============================================================
-- 场景2：不使用 CTE 的子查询（AVG(val) 被重复计算）
-- ============================================================
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data) * 2;
-- AVG(val) 被计算了两次，每次子查询都需要全表扫描 10 万行

-- ============================================================
-- EXPLAIN 查看执行计划
-- ============================================================
EXPLAIN SELECT t1.name AS l1, t2.name AS l2, t3.name AS l3
FROM t_tree t1
LEFT JOIN t_tree t2 ON t2.parent_id = t1.id
LEFT JOIN t_tree t3 ON t3.parent_id = t2.id
WHERE t1.parent_id IS NULL
LIMIT 20;

EXPLAIN SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data)
UNION ALL
SELECT * FROM t_cte_data WHERE val > (SELECT AVG(val) FROM t_cte_data) * 2;
