-- bad.sql: 派生表物化后外层过滤（5.7 无法下推）
--
-- 原理:
--   1. FROM 子查询 (SELECT user_id, COUNT(*) ... GROUP BY user_id) 是派生表
--   2. MySQL 5.7 中派生表会被物化为临时表:
--      - 先执行子查询，将全部分组结果(5000行)物化到临时表
--      - 外层 WHERE cnt > 100 在物化后的临时表上过滤
--      - 无法将 cnt > 100 下推到子查询内部（HAVING）
--   3. 虽然 5000 行物化不算大，但当分组数达到百万级时物化代价显著
--   4. MySQL 8.0 优化器可做条件下推，将外层条件下推为子查询的 HAVING
--      但并非所有场景都能下推，依赖优化器判断
--
--   问题本质: 用派生表包裹 GROUP BY，再在外层过滤聚合结果，
--   不如直接用 HAVING 在聚合时过滤。
SELECT *
FROM (
    SELECT
        user_id,
        COUNT(*)    AS cnt,
        AVG(response_time) AS avg_rt
    FROM t_access_log
    GROUP BY user_id
) t
WHERE cnt > 100
ORDER BY cnt DESC;
