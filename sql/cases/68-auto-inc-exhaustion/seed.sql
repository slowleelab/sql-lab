-- ============================================================
-- 造数据: bad 表插入少量数据（AUTO_INCREMENT 已设为接近上限）
--         good 表插入相同数据量（用模拟雪花 ID）
-- ============================================================

-- bad 表：插入 10 行，AUTO_INCREMENT 从 4294967290 开始
-- 再插 5 行就会溢出（4294967290 + 6 = 4294967296 > 4294967295）
INSERT INTO t_order_bad (order_no, user_id, amount, status, created_at) VALUES
    ('ORD000001', 1001, 99.90,  1, NOW()),
    ('ORD000002', 1002, 199.00, 1, NOW()),
    ('ORD000003', 1003, 50.50,  1, NOW()),
    ('ORD000004', 1004, 299.99, 1, NOW()),
    ('ORD000005', 1005, 10.00,  1, NOW());

-- good 表：插入相同数据，用模拟雪花 ID
-- 雪花 ID 格式：时间戳(41bit) + 机器ID(10bit) + 序列号(12bit)
-- 这里用递增大数模拟，实际由应用层生成
INSERT INTO t_order_good (id, order_no, user_id, amount, status, created_at) VALUES
    (1752500000000000001, 'ORD000001', 1001, 99.90,  1, NOW()),
    (1752500000000000002, 'ORD000002', 1002, 199.00, 1, NOW()),
    (1752500000000000003, 'ORD000003', 1003, 50.50,  1, NOW()),
    (1752500000000000004, 'ORD000004', 1004, 299.99, 1, NOW()),
    (1752500000000000005, 'ORD000005', 1005, 10.00,  1, NOW());

-- 查看 bad 表的自增水位
SELECT AUTO_INCREMENT AS bad_next_id,
       4294967295 - AUTO_INCREMENT AS bad_remaining_slots
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_bad';

-- 查看 good 表的最大 ID（无自增水位概念）
SELECT MAX(id) AS good_max_id FROM t_order_good;
