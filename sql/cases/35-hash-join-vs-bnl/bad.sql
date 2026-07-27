-- bad.sql: 无索引 JOIN 查询
-- t_b.a_id 无索引，JOIN 走非索引路径:
--   5.7: Block Nested Loop (BNL)，对 t_a 每行全扫 t_b，O(n*m)
--   8.0: Hash Join，对小表建哈希表后探测大表，O(n+m)，比 BNL 快但仍需全扫
-- WHERE a.val > 49000 过滤出 t_a 少量行，但被驱动表无索引仍需全表扫描
SELECT a.name, b.data
FROM t_a a
JOIN t_b b ON b.a_id = a.id
WHERE a.val > 49000;
