-- bad.sql: 非最优 Join 算法场景

-- 场景1: 两张大表连接无索引
-- t_join_a ⨝ t_join_c（c_val 无索引）→ Hash Join 全量扫描
EXPLAIN SELECT a.a_name, a.a_val, c.c_name, c.c_val
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景2: 大表 JOIN 大表（优化器可能选择 Hash Join 而非 Index Join）
EXPLAIN SELECT a.a_name, b.b_name, a.a_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- 场景3: 非等值连接只能走 Hash Join
EXPLAIN SELECT a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val > b.b_val;
