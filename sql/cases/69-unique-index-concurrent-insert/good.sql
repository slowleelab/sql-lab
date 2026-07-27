-- good.sql: INSERT ... ON DUPLICATE KEY UPDATE 原子解决并发冲突
-- 单条语句原子完成"不存在则插入，存在则更新"，无竞态窗口
-- 若 uk_code 已存在，触发 ON DUPLICATE KEY UPDATE 更新 counter，不报错

-- 原子 upsert：不存在则插入，存在则 counter+1
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE_NEW', 1, NOW())
ON DUPLICATE KEY UPDATE counter = counter + 1, updated_at = NOW();

-- 对于已存在的记录（如 CODE00001），同样原子更新计数
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE00001', 1, NOW())
ON DUPLICATE KEY UPDATE counter = counter + 1, updated_at = NOW();
