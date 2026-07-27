-- bad.sql: 5.7 中派生表全量物化，外层 WHERE 无法下推
--
-- 问题分析：
--   1. FROM 子查询 (SELECT user_id, SUM(amount) as total FROM t_order GROUP BY user_id)
--      是派生表
--   2. MySQL 5.7 中派生表会被完整物化为临时表:
--      - 先执行子查询，对 100 万行订单按 user_id 分组
--      - 将 10 万个分组结果物化到临时表
--      - 外层 WHERE t.user_id = 100 在物化后的临时表上过滤
--   3. 物化了 10 万行，但最终只需要 1 行（user_id=100）
--   4. 浪费了 99999 行的分组和物化开销
--
--   问题本质: 先全量分组物化，再外层过滤，不如先过滤再分组

SELECT *
FROM (
    SELECT user_id, SUM(amount) AS total
    FROM t_order
    GROUP BY user_id
) t
WHERE t.user_id = 100;
