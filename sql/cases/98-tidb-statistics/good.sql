-- good.sql: 主动更新统计信息

-- 1. 手动 ANALYZE 更新统计
ANALYZE TABLE t_stats;

-- 2. 查看更新后的统计健康度
SHOW STATS_HEALTHY WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 3. 再次 EXPLAIN——统计恢复准确后，优化器选择正确索引
EXPLAIN SELECT * FROM t_stats WHERE status = 1 AND city = 'Beijing';

-- 4. 查看列的直方图信息
SHOW STATS_HISTOGRAMS WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 5. 查看列的 Count-Min Sketch 桶信息
SHOW STATS_BUCKETS WHERE db_name = 'sql_treasure' AND table_name = 't_stats';

-- 6. 查看统计元数据（行数、修改行数、健康度）
SHOW STATS_META WHERE db_name = 'sql_treasure' AND table_name = 't_stats';
