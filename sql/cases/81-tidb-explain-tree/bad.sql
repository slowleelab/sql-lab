-- bad.sql: TiDB EXPLAIN 算子解读（通过 EXPLAIN 对比理解执行计划）

-- 场景1: 全表扫描 TableFullScan
-- 无 WHERE 条件的扫描，id 列为 TableReader + TableFullScan
EXPLAIN SELECT * FROM t_user;

-- 场景2: 索引范围扫描 IndexRangeScan
-- 走 idx_age 索引，access object 显示使用的索引名和范围条件
EXPLAIN SELECT * FROM t_user WHERE age > 18 AND age < 30;

-- 场景3: IndexLookUp 回表
-- 非覆盖索引查询：先 Build(IndexRangeScan) 扫描索引，再 Probe(TableRowIDScan) 回表
EXPLAIN SELECT id, name, city, salary FROM t_user WHERE city = 'Beijing';

-- 场景4: cop[tikv] vs root task 示例
-- cop[tikv] 表示下推到 TiKV 执行，root 表示在 TiDB server 执行
EXPLAIN SELECT city, COUNT(*) AS cnt, AVG(salary) AS avg_salary
FROM t_user
GROUP BY city
ORDER BY cnt DESC;
