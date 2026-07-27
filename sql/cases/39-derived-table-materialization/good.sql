-- good.sql: 直接 GROUP BY HAVING，避免派生表物化
--
-- 原理:
--   1. 将外层 WHERE cnt > 100 改写为子查询内部的 HAVING COUNT(*) > 100
--   2. 聚合时直接过滤，只产出满足条件的行，无需物化全部分组结果
--   3. 5.7 中彻底避免派生表物化（没有 FROM 子查询了）
--   4. 8.0 中虽然能下推，但直接 HAVING 仍更高效，省去派生表层
--
--   bad 方案: GROUP BY 全量物化 -> 外层 WHERE 过滤
--   good 方案: GROUP BY HAVING 直接过滤聚合
SELECT
    user_id,
    COUNT(*)           AS cnt,
    AVG(response_time) AS avg_rt
FROM t_access_log
GROUP BY user_id
HAVING COUNT(*) > 100
ORDER BY cnt DESC;
