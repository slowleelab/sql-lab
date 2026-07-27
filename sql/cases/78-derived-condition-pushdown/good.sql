-- good.sql: 8.0 中同样的 SQL，优化器自动将条件下推到派生表内部
--
-- 优化原理：
--   1. MySQL 8.0 支持派生条件下推（derived condition pushdown）
--   2. 优化器将外层 WHERE t.user_id = 100 下推到派生表内部
--   3. 等价于: SELECT user_id, SUM(amount) FROM t_order WHERE user_id = 100 GROUP BY user_id
--   4. 只分组 user_id=100 的约 10 行数据，而非全量 100 万行
--   5. 物化行数从 10 万降到 1，性能提升显著
--
-- 8.0 的派生条件下推是自动的，无需修改 SQL
-- 5.7 中需手动改写（将条件下推到子查询内部）

SELECT *
FROM (
    SELECT user_id, SUM(amount) AS total
    FROM t_order
    GROUP BY user_id
) t
WHERE t.user_id = 100;
