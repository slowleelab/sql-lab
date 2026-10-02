-- bad.sql: 非覆盖索引导致 IndexLookUp 回表

-- 场景1: 查询列不在索引中，触发 IndexLookUp
-- SELECT name, email, bio 三个列都不在 idx_city 索引中
EXPLAIN SELECT id, name, email, bio FROM t_lookup WHERE city = 'Beijing';

-- 场景2: 回表读取大量数据
-- idx_user 能找到行，但需要回表读 age/city/bio
EXPLAIN SELECT id, user_id, age, city, bio FROM t_lookup WHERE user_id BETWEEN 1000 AND 2000;

-- 场景3: ORDER BY + 非覆盖索引
-- idx_age_city 可用于排序，但 SELECT * 导致仍需回表
EXPLAIN SELECT * FROM t_lookup WHERE age > 20 AND age < 30 ORDER BY city;
