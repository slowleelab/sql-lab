-- bad.sql: INT 自增主键耗尽场景
-- AUTO_INCREMENT 已到 4294967295（INT UNSIGNED 上限），继续 INSERT 直接报错
-- 这不是慢查询，而是"直接写不进去"的致命故障

-- 模拟 ID 耗尽：插入到第 6 行时触发溢出
INSERT INTO t_order_bad (order_no, user_id, amount, status, created_at)
VALUES ('ORD_OVERFLOW', 9999, 1.00, 0, NOW());

-- 预期报错: ERROR 1467 (HY000): Failed to read auto-increment value from storage engine
-- 或: ERROR 1062 (23000): Duplicate entry '4294967295' for key 'PRIMARY'

-- 查看剩余可用 ID 数量（已为 0）
SELECT AUTO_INCREMENT AS current_auto_inc,
       4294967295 - AUTO_INCREMENT AS remaining_slots
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_bad';
