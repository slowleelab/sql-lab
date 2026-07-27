-- bad.sql: STRAIGHT_JOIN 强制最差顺序 大表 -> 中表 -> 小表
-- 先扫 20 万行大表，再去中表匹配，中间结果集巨大，
-- 最后才过滤小表 val=1，前面大量 JOIN 计算被浪费。
SELECT STRAIGHT_JOIN s.*
FROM t_large l
JOIN t_medium m ON m.id = l.medium_id
JOIN t_small s ON s.id = m.small_id
WHERE s.val = 1;
