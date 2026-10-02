-- good.sql: 用临时表 JOIN 替代大 IN 列表（需先执行 setup-good.sql 建临时表）
-- 优化器走标准的 JOIN 路径: 临时表(1000行) 驱动 t_order_in，通过 idx_user 索引查找。
-- 执行计划稳定可控，且临时表可建索引、可复用，避免了 IN 列表的解析膨胀问题。
SELECT o.*
FROM t_order_in o
INNER JOIN tmp_target_users t ON o.user_id = t.user_id;
