-- good.sql: 改用相关子查询 EXISTS
-- EXISTS 是相关子查询，对外表(t_emp)每行执行一次内层查询，
-- 一旦在 t_dept 命中即短路返回 true，配合 t_dept 的主键查找很快。
-- 本案例(外表大内表小)两种写法在 8.0 上执行计划通常一致，
-- 但 EXISTS 显式表达了"逐行探测"语义，在优化器改写失效时更稳健。
-- 注意: 若是"外表小内表大"场景，则反过来 IN 更优。
SELECT *
FROM t_emp e
WHERE EXISTS (
    SELECT 1 FROM t_dept d
    WHERE d.id = e.dept_id AND d.name LIKE '技术%'
);
