-- bad.sql: 先 SELECT 检查再 INSERT（TOCTOU 竞态条件）
-- 两个并发事务都先查询 uk_code 不存在，然后都执行 INSERT，导致唯一键冲突
--
-- TOCTOU 竞态复现（需两个会话）：
--
--   会话A:
--     BEGIN;
--     SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在
--
--   会话B:
--     BEGIN;
--     SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在
--
--   会话A:
--     INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);  -- 成功
--     COMMIT;
--
--   会话B:
--     INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);
--     -- ❌ ERROR 1062 (23000): Duplicate entry 'CODE_NEW' for key 'uk_code'
--     -- 唯一键冲突！SELECT 和 INSERT 之间有时间窗口，并发下不可靠

-- 步骤1: 先查询检查是否存在（TOCTOU 的 Check 阶段）
SELECT COUNT(*) AS exists_flag FROM t_unique_test WHERE uk_code = 'CODE_NEW';

-- 步骤2: 若 exists_flag=0 则插入（TOCTOU 的 Use 阶段，存在竞态窗口）
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE_NEW', 1, NOW());
