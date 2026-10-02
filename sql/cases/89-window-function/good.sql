-- good.sql: 用 ROW_NUMBER() 窗口函数查每个部门薪资最高的员工
--
-- 原理:
--   ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC)
--   按 dept 分组，组内按 salary 降序编号 1,2,3...
--   外层过滤 rn = 1 即取每部门薪资最高的员工。
--
--   优势:
--   - 单次扫描完成分组排序，无需相关子查询
--   - 优化器可利用 idx_dept_salary (dept, salary) 索引有序性
--   - 逻辑清晰，性能稳定
SELECT id, emp_name, dept, salary
FROM (
    SELECT id, emp_name, dept, salary,
           ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn
    FROM t_salary
) ranked
WHERE rn = 1
ORDER BY dept;
