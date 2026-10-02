-- setup-bad.sql: 关闭索引下推 ICP
SET SESSION optimizer_switch = 'index_condition_pushdown=off';
