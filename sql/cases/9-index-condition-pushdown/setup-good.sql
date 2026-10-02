-- setup-good.sql: 开启索引下推 ICP（MySQL 5.6+ 默认开启）
SET SESSION optimizer_switch = 'index_condition_pushdown=on';
