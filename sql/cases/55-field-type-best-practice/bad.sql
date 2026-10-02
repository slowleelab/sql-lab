-- bad.sql: 字段类型选择随意导致的性能与精度问题

-- =====================================================================
-- 查询 1: status 用 VARCHAR(20)，字符串比较比整数比较慢
--   中文字符串在 utf8mb4 下每字符最多 4 字节，'已支付' 占 12 字节
--   索引 key_len = 20*4+2 = 82 字节，索引体积大，字符串比较需逐字节比对
-- =====================================================================
SELECT id, order_no, status, amount
FROM t_type_bad
WHERE status = '已支付';

-- =====================================================================
-- 查询 2: amount 用 FLOAT，精度问题导致等值比较不可靠
--   FLOAT 是近似浮点存储，99.90 实际存为 99.9000015258789
--   amount = 99.90 可能查不到任何行（精确匹配失败）
--   seed 中每 1000 行插入一个 99.90，共 100 行，但可能查出 0 行
-- =====================================================================
SELECT id, order_no, amount
FROM t_type_bad
WHERE amount = 99.90;
-- 预期: 可能返回 0 行！FLOAT 存储的 99.90 实际是 99.9000015258789

-- 验证 FLOAT 的精度偏差
SELECT id, amount,
       amount - 99.90 AS diff
FROM t_type_bad
WHERE id <= 1001 AND MOD(id, 1000) = 0
ORDER BY id;

-- =====================================================================
-- 查询 3: phone VARCHAR(50) 的索引比 VARCHAR(20) 大很多
--   实际手机号仅 11 位，VARCHAR(50) 索引按定义长度计算
--   key_len = 50*4+2 = 202 字节（是 VARCHAR(20) 的 82 字节的 2.5 倍）
-- =====================================================================
SELECT id, order_no, phone
FROM t_type_bad
WHERE phone = '13800138000';

-- =====================================================================
-- 查询 4: is_deleted 用 VARCHAR(5)，字符串比较 + 索引膨胀
--   'true'/'false' 字符串比较，应改 TINYINT(1)
-- =====================================================================
SELECT COUNT(*) AS deleted_count
FROM t_type_bad
WHERE is_deleted = 'true';

-- =====================================================================
-- 查看 bad 表的存储大小与索引大小
-- =====================================================================
SELECT TABLE_NAME, TABLE_ROWS,
       ROUND(DATA_LENGTH/1024/1024, 2) AS data_mb,
       ROUND(INDEX_LENGTH/1024/1024, 2) AS index_mb,
       ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024, 2) AS total_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_type_bad';

-- 查看 bad 表各索引定义与 key_len
SELECT INDEX_NAME, COLUMN_NAME, SUB_PART,
       CASE
           WHEN COLUMN_NAME = 'status' THEN 82
           WHEN COLUMN_NAME = 'phone'  THEN 202
           WHEN COLUMN_NAME = 'user_id' THEN 8
       END AS estimated_key_len
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_type_bad'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
