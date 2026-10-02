-- good.sql: 执行 OPTIMIZE TABLE 后查询（碎片已整理）
--
-- 原理:
--   1. OPTIMIZE TABLE 重建表:
--      - 8.0: 使用 inplace 重建（ALGORITHM=COPY 或 INSTANT 不适用时用 COPY）
--        实际是 CREATE 新表 -> 复制数据 -> RENAME -> DROP 旧表
--      - 5.7: 使用 COPY 方式重建
--   2. 重建后:
--      - DATA_FREE 大幅降低（碎片空间被回收）
--      - DATA_LENGTH 降低（紧凑存储，无空洞）
--      - 索引 B+ 树重新组织，扫描效率提升
--   3. 物理空间释放给操作系统（ibd 文件缩小）
--
--   注意: OPTIMIZE TABLE 期间表不可写（MDL 锁），需在低峰期执行
--         8.0 可用 ALTER TABLE ... ENGINE=InnoDB 等效重建

-- 查看碎片整理后的状态（DATA_FREE 和 DATA_LENGTH 应显著降低）:
SELECT
    table_name,
    table_rows                                          AS rows_count,
    ROUND(data_length / 1024 / 1024, 2)                 AS data_mb,
    ROUND(index_length / 1024 / 1024, 2)                AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)                   AS free_mb,
    ROUND(data_free / (data_length + index_length) * 100, 2) AS free_pct
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';

-- 查询碎片整理后的效率（数据页紧凑，I/O 减少）:
SELECT
    user_id, COUNT(*) AS order_cnt, SUM(amount) AS total_amount
FROM t_fragment_order
WHERE status = 1
GROUP BY user_id
ORDER BY total_amount DESC
LIMIT 20;
