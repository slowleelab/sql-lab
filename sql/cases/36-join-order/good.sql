-- good.sql: STRAIGHT_JOIN 强制最优顺序 小表 -> 中表 -> 大表
-- 先用小表 val=1 过滤出极少行（约 100 行），再驱动中表 (idx_small_id)，
-- 再驱动大表 (idx_medium_id)，每步结果集都很小，扫描行数大幅下降。
SELECT STRAIGHT_JOIN l.*
FROM t_small s
JOIN t_medium m ON m.small_id = s.id
JOIN t_large l ON l.medium_id = m.id
WHERE s.val = 1;
