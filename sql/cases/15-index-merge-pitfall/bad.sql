-- bad.sql: WHERE status=1 OR city='北京'，两个条件各自有索引
-- MySQL 优化器选择 index_merge(union)，分别扫描 idx_status 和 idx_city，
-- 再将两个结果集合并去重。status=1 匹配约 20 万行，city='北京' 匹配约 1 万行，
-- index_merge 需要合并 21 万行结果集，开销远大于直接全表扫描。
SELECT *
FROM t_user_merge
WHERE status = 1
   OR city = '北京';
