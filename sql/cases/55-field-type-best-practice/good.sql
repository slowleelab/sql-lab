-- good.sql: 精心选择字段类型，存储紧凑、索引小、无精度问题

-- =====================================================================
-- 查询 1: TINYINT UNSIGNED 整数比较，比字符串比较更快
--   status TINYINT 占 1 字节，索引 key_len = 1
--   整数比较是 CPU 单条指令，无需逐字节比对字符
-- =====================================================================
SELECT id, order_no, status, amount
FROM t_type_good
WHERE status = 1;

-- =====================================================================
-- 查询 2: DECIMAL(10,2) 精确存储，等值比较可靠
--   DECIMAL 是精确十进制存储，99.90 就是 99.90，无精度偏差
--   seed 中每 1000 行插入一个 99.90，共 100 行，全部可精确查出
-- =====================================================================
SELECT id, order_no, amount
FROM t_type_good
WHERE amount = 99.90;

-- 验证 DECIMAL 无精度偏差
SELECT id, amount,
       amount - 99.90 AS diff
FROM t_type_good
WHERE id <= 1001 AND MOD(id, 1000) = 0
ORDER BY id;

-- =====================================================================
-- 查询 3: VARCHAR(20) 索引比 VARCHAR(50) 小很多
--   手机号 11 位，VARCHAR(20) 足够，索引 key_len = 20*4+2 = 82 字节
--   比 VARCHAR(50) 的 202 字节缩减 59%
-- =====================================================================
SELECT id, order_no, phone
FROM t_type_good
WHERE phone = '13800138000';

-- =====================================================================
-- 查询 4: is_deleted 用 TINYINT(1)，整数比较 + 索引小
-- =====================================================================
SELECT COUNT(*) AS deleted_count
FROM t_type_good
WHERE is_deleted = 1;

-- =====================================================================
-- 对比两张表的存储大小与索引大小（核心量化对比）
-- =====================================================================
SELECT TABLE_NAME, TABLE_ROWS,
       ROUND(DATA_LENGTH/1024/1024, 2) AS data_mb,
       ROUND(INDEX_LENGTH/1024/1024, 2) AS index_mb,
       ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024, 2) AS total_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 't_type_%'
ORDER BY TABLE_NAME;

-- =====================================================================
-- 查看两表各索引的 key_len 对比（status / phone 差异最大）
-- =====================================================================
SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME,
       CASE
           WHEN TABLE_NAME = 't_type_bad'  AND COLUMN_NAME = 'status' THEN 82
           WHEN TABLE_NAME = 't_type_good' AND COLUMN_NAME = 'status' THEN 1
           WHEN TABLE_NAME = 't_type_bad'  AND COLUMN_NAME = 'phone'  THEN 202
           WHEN TABLE_NAME = 't_type_good' AND COLUMN_NAME = 'phone'  THEN 82
           WHEN COLUMN_NAME = 'user_id' THEN 8
       END AS estimated_key_len
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 't_type_%'
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;

-- =====================================================================
-- 量化每行的平均存储开销对比
-- =====================================================================
SELECT TABLE_NAME,
       TABLE_ROWS,
       ROUND(DATA_LENGTH/TABLE_ROWS, 2) AS avg_row_bytes,
       ROUND(INDEX_LENGTH/TABLE_ROWS, 2) AS avg_idx_bytes
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 't_type_%'
ORDER BY TABLE_NAME;
