-- bad.sql: 用相关子查询查每个部门薪资最高的员工
--
-- 原理:
--   对外层每行 s，执行子查询 SELECT MAX(salary) FROM t_salary s2 WHERE s2.dept = s.dept
--   若当前行薪资等于该部门最高薪资，则保留。
--
--   问题:
--   1. 相关子查询: 外层每一行都触发一次子查询
--   2. 10 万行 -> 约 10 万次子查询执行
--   3. 每次子查询都扫描该部门约 1000 行算 MAX，累计开销巨大
SELECT s.id, s.emp_name, s.dept, s.salary
FROM t_salary s
WHERE s.salary = (
    SELECT MAX(s2.salary)
    FROM t_salary s2
    WHERE s2.dept = s.dept
)
ORDER BY s.dept, s.salary DESC;
