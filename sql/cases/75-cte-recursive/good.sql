-- good.sql: 8.0 递归 CTE 一条语句遍历任意深度层级
-- WITH RECURSIVE 自动递归到所有层级，无需写死 JOIN 次数
WITH RECURSIVE org_tree AS (
    -- 锚点: 起始节点（VP-1）
    SELECT id, emp_name, manager_id, level
    FROM t_employee_org
    WHERE emp_name = 'VP-1'

    UNION ALL

    -- 递归: 逐层向下找下属
    SELECT e.id, e.emp_name, e.manager_id, e.level
    FROM t_employee_org e
    INNER JOIN org_tree ot ON e.manager_id = ot.id
)
SELECT id, emp_name, level
FROM org_tree
ORDER BY level, id;
