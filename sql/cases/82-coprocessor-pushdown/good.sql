-- good.sql: 下推成功的等价写法

-- 正解1: 避免在 WHERE 中使用函数，让条件直接下推
-- city 字段无函数包裹，TiKV 可以直接用索引过滤
EXPLAIN SELECT * FROM t_pushdown WHERE city = 'Beijing';

-- 正解2: 用范围条件替代函数
-- 范围条件可以下推到 TiKV，利用 idx_city 或主键扫描
EXPLAIN SELECT * FROM t_pushdown WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';

-- 正解3: 精确匹配替代 LIKE（同时利用 IS NOT NULL 可下推）
-- IS NOT NULL 可以下推到 TiKV，避免全量传输
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio IS NOT NULL LIMIT 100;
