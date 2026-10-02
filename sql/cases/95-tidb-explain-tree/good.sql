-- good.sql: TiDB EXPLAIN 高级用法

-- EXPLAIN ANALYZE: 实际执行并显示各算子的真实耗时和行数
EXPLAIN ANALYZE SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';

-- EXPLAIN FORMAT=verbose: 显示更多算子树细节
EXPLAIN FORMAT=verbose SELECT city, COUNT(*) AS cnt FROM t_user GROUP BY city;

-- 覆盖索引避免回表（IndexReader 替代 IndexLookUp）
-- 查询只涉及索引中的列时，TiDB 使用 IndexReader 直接扫描索引
EXPLAIN SELECT city FROM t_user WHERE city = 'Beijing';
