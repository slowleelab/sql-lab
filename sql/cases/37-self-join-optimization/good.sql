-- good.sql: 移除函数包裹，让 manager_id 走索引
--
-- 原理:
--   1. 去掉 JOIN 条件中的 IFNULL() 函数包裹，直接用 e1.manager_id = e2.id
--      这样被驱动表 e2 走主键，驱动表 e1 的 department 过滤走 idx_department
--   2. seed 数据中 manager_id=0 的行表示无上级，LEFT JOIN 时 e2.id 无匹配返回 NULL
--      与 bad 方案 IFNULL(...,0) 的语义一致，但不破坏索引使用
--   3. 优化器可利用 idx_department 定位"技术部"员工，再用主键关联上级信息
--
--   bad 方案: IFNULL 包裹索引列 -> 索引失效 -> 全表扫描驱动
--   good 方案: 原始列参与 JOIN -> 索引有效 -> 索引范围扫描驱动
SELECT
    e1.id           AS emp_id,
    e1.emp_name     AS emp_name,
    e1.department   AS department,
    e1.salary       AS salary,
    e2.emp_name     AS manager_name
FROM t_employee e1
LEFT JOIN t_employee e2 ON e1.manager_id = e2.id
WHERE e1.department = '技术部'
ORDER BY e1.id
LIMIT 100;
