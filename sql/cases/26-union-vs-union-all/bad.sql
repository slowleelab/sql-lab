-- bad.sql: UNION 自动去重，需创建临时表并排序去重
-- 两表数据天然无重复，去重操作纯属浪费
SELECT code, name FROM t_source_a
UNION
SELECT code, name FROM t_source_b;
