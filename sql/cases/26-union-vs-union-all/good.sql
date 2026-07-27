-- good.sql: UNION ALL 不去重，直接拼接结果，更快
-- 已知两表 code 前缀不同（A/B），无重复行
SELECT code, name FROM t_source_a
UNION ALL
SELECT code, name FROM t_source_b;
