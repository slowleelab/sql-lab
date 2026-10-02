-- setup-good.sql: 执行 OPTIMIZE TABLE 重建表回收碎片
--
-- OPTIMIZE TABLE 等价于:
--   ALTER TABLE t_fragment_order ENGINE=InnoDB;
--   ANALYZE TABLE t_fragment_order;
--
-- 8.0 中 OPTIMIZE TABLE 使用 ALGORITHM=COPY，会:
--   1. 创建临时表（.ibd 文件）
--   2. 逐行复制存活数据到新表
--   3. RENAME 替换旧表
--   4. DROP 旧表及其 ibd 文件
--   5. 更新统计信息
--
-- 执行前请确认:
--   - 低峰期执行（MDL 锁会阻塞写入）
--   - 磁盘空间充足（需要原表大小的临时空间）

OPTIMIZE TABLE t_fragment_order;

-- 等效写法（8.0 推荐，语义更清晰）:
-- ALTER TABLE t_fragment_order ENGINE=InnoDB, ALGORITHM=COPY, LOCK=SHARED;

-- 验证碎片已整理:
SELECT
    table_name,
    table_rows,
    ROUND(data_length / 1024 / 1024, 2)  AS data_mb,
    ROUND(index_length / 1024 / 1024, 2) AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)    AS free_mb
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';
