-- bad.sql: 自连接但 manager_id 被函数包裹导致索引失效
--
-- 原理:
--   schema 中已存在 idx_manager (manager_id) 索引，
--   但本查询在 JOIN 条件中使用 IFNULL(e1.manager_id, 0) = e2.id，
--   对索引列施加了函数包裹，导致优化器无法使用 idx_manager 索引。
--   被驱动表 e2 只能走主键，但驱动表 e1 的 manager_id 列无法走索引定位，
--   整个查询退化为对全表的扫描 + 主键逐行探测。
--
--   实际业务中常见的写法陷阱:
--   - IFNULL(manager_id, 0) = ...
--   - COALESCE(manager_id, 0) = ...
--   - manager_id + 0 = ...
SELECT
    e1.id           AS emp_id,
    e1.emp_name     AS emp_name,
    e1.department   AS department,
    e1.salary       AS salary,
    e2.emp_name     AS manager_name
FROM t_employee e1
LEFT JOIN t_employee e2 ON IFNULL(e1.manager_id, 0) = e2.id
WHERE e1.department = '技术部'
ORDER BY e1.id
LIMIT 100;
