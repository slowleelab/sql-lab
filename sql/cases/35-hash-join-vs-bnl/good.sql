-- good.sql: 同样查询，但 t_b.a_id 已有索引（需先执行 setup-good.sql）
-- 加索引后走 Index Nested Loop Join:
--   驱动表 t_a 过滤后少量行，每行通过 idx_a_id 在 t_b 做索引查找
--   无需全表扫描 t_b，远快于 Hash Join / BNL
SELECT a.name, b.data
FROM t_a a
JOIN t_b b ON b.a_id = a.id
WHERE a.val > 49000;
