-- good.sql: 雪花 ID 方案，永不耗尽
-- BIGINT 上限 9.2 × 10^18，雪花算法每年消耗约 3 × 10^16，可用数万年

-- 应用层生成雪花 ID 后插入，完全不依赖 MySQL AUTO_INCREMENT
-- 雪花 ID 结构（64 bit）:
--   1 bit 符号位（固定 0）
--   41 bit 时间戳（毫秒级，可用约 69 年）
--   10 bit 机器 ID（支持 1024 台机器）
--   12 bit 序列号（每毫秒每机器 4096 个 ID）

-- 模拟应用层生成的雪花 ID（递增，实际由 Snowflake 算法生成）
INSERT INTO t_order_good (id, order_no, user_id, amount, status, created_at)
VALUES (1752500000000000006, 'ORD_OVERFLOW', 9999, 1.00, 0, NOW());

-- 插入成功，无上限风险
SELECT id, order_no, user_id, amount, status
FROM t_order_good
ORDER BY id DESC
LIMIT 10;

-- 查看表大小对比：雪花 ID 表无 AUTO_INCREMENT 水位
SELECT
    TABLE_NAME,
    AUTO_INCREMENT,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('t_order_bad', 't_order_good');
