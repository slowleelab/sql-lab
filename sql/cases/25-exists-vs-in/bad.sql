-- bad.sql: 用 IN 子查询查询"技术%"部门的员工
-- 外表 t_emp(30万) 大，内表 t_dept(100，过滤后~5行) 小。
-- 原理上 IN 子查询语义是"小表驱动大表"，但写法依赖优化器改写:
--   5.7 若未改写为 semi-join，可能对 t_emp 每行执行一次子查询，效率低；
--   8.0 通常自动改写为 semi-join，表现与 good 相当。
-- 在优化器未能改写的场景下，这种写法可能退化为低效执行计划。
SELECT *
FROM t_emp
WHERE dept_id IN (SELECT id FROM t_dept WHERE name LIKE '技术%');
