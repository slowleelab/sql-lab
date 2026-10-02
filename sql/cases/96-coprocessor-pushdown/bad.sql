-- bad.sql: 下推失败的场景

-- 场景1: 函数包裹字段导致下推失败
-- LOWER(city) 无法下推，全表数据拉取到 TiDB
-- TiKV 无法识别 LOWER 函数，必须将 city 列全量返回给 TiDB 再过滤
EXPLAIN SELECT * FROM t_pushdown WHERE LOWER(city) = 'beijing';

-- 场景2: 复杂表达式下推失败
-- YEAR(created_at) = 2025 无法下推
-- 因为 YEAR() 函数不在 TiKV 协处理器支持的函数列表中
EXPLAIN SELECT * FROM t_pushdown WHERE YEAR(created_at) = 2025;

-- 场景3: TEXT 字段上的 LIKE 可能影响下推
-- bio 是 TEXT 类型，'%keyword%' 以通配符开头，
-- 下推行为受限，可能仍需将数据拉取到 TiDB 处理
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio LIKE '%keyword%';
