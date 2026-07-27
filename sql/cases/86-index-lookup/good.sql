-- good.sql: 覆盖索引避免 IndexLookUp

-- 正解1: 只查索引中的列（覆盖索引）
-- city 在 idx_city 中，id 自动附加在二级索引中
EXPLAIN SELECT id, city FROM t_lookup WHERE city = 'Beijing';

-- 正解2: 利用 idx_age_city 覆盖索引（age + city + id）
-- 查询 age/city/id 三个列都在 idx_age_city 索引中，无需回表
EXPLAIN SELECT id, age, city FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;

-- 正解3: Cluster Index 表的主键查询直接定位行
-- t_cluster_lookup 主键即聚簇索引，无需额外回表
EXPLAIN SELECT * FROM t_cluster_lookup WHERE id = 50000;

-- 对比：普通表的主键查询与 Cluster Index 无差异（均为聚簇索引）
EXPLAIN SELECT * FROM t_lookup WHERE id = 50000;

-- 正解4: 建立专用覆盖索引
-- 如果需要频繁查询 city + name，建立包含 name 的联合索引
ALTER TABLE t_lookup ADD KEY idx_city_name (city, name);
EXPLAIN SELECT id, city, name FROM t_lookup WHERE city = 'Beijing';
