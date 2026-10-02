-- bad.sql: 查询碎片表（DELETE 后未优化）
--
-- 原理:
--   1. t_fragment_order 插入 20 万行后 DELETE 了 70%（约 14 万行）
--   2. InnoDB DELETE 只标记行为"已删除"，不释放物理页空间给操作系统
--   3. 表的 DATA_FREE 较大（碎片空间），DATA_LENGTH 仍按原大小计算
--   4. 查询时仍需扫描包含"空洞"的数据页，I/O 效率下降
--   5. 索引 B+ 树也存在碎片，扫描效率降低
--
--   查看碎片状态:
SELECT
    table_name,
    table_rows                                          AS rows_count,
    ROUND(data_length / 1024 / 1024, 2)                 AS data_mb,
    ROUND(index_length / 1024 / 1024, 2)                AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)                   AS free_mb,
    ROUND(data_free / (data_length + index_length) * 100, 2) AS free_pct
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';

-- 查询碎片表的效率（扫描包含空洞的数据页）:
SELECT
    user_id, COUNT(*) AS order_cnt, SUM(amount) AS total_amount
FROM t_fragment_order
WHERE status = 1
GROUP BY user_id
ORDER BY total_amount DESC
LIMIT 20;
