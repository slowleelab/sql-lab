-- good.sql: 根据场景选择最优 Join 算法

-- 场景1: 小表有索引 → Index Join (INLJ)
-- 给 t_join_c 加索引后可用 Index Join
ALTER TABLE t_join_c ADD KEY idx_val (c_val);
EXPLAIN SELECT a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景2: 等值连接 + 索引 → 查看优化器选择的 Join 类型
EXPLAIN SELECT a.a_name, b.b_name, a.a_val, b.b_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- 场景3: 显式指定 Join 算法 Hint

-- Hash Join Hint
EXPLAIN SELECT /*+ HASH_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- Merge Join Hint（需要两表均按连接列排序）
EXPLAIN SELECT /*+ MERGE_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val WHERE a.a_val < 100;

-- Index Join Hint
EXPLAIN SELECT /*+ INL_JOIN(c) */ a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景4: Broadcast Join 控制
SHOW VARIABLES LIKE 'tidb_prefer_broadcast_join';
SET SESSION tidb_prefer_broadcast_join = ON;
EXPLAIN SELECT a.a_name, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
SET SESSION tidb_prefer_broadcast_join = DEFAULT;
