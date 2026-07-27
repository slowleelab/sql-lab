-- bad.sql: 传统多次自连接查询某 VP 下所有层级的下属
-- 5 层结构需要 4 次自连接，层数写死；若层数变化需改 SQL
-- 假设查询 VP-1 (level 2) 下所有下属（level 3/4/5）
SELECT
    e5.id, e5.emp_name, e5.level
FROM t_employee_org e2
JOIN t_employee_org e3 ON e3.manager_id = e2.id
JOIN t_employee_org e4 ON e4.manager_id = e3.id
JOIN t_employee_org e5 ON e5.manager_id = e4.id
WHERE e2.emp_name = 'VP-1';
