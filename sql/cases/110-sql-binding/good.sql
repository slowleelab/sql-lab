-- good.sql: 使用 CREATE GLOBAL BINDING 强制锁定执行计划

-- ============================================================
-- 1. CREATE GLOBAL BINDING 绑定执行计划
--    将原始 SQL 与带 Hint 的 SQL 绑定，强制使用 idx_status 索引
-- ============================================================
CREATE GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20
USING
  SELECT /*+ USE_INDEX(t_spm_test, idx_status) */ * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;

-- ============================================================
-- 2. 确认绑定已生效
-- ============================================================
SHOW GLOBAL BINDINGS;

-- ============================================================
-- 3. 查看绑定的详细信息
--    注意：SPM 对 SQL 做参数化匹配，常量值会被归一化为 ?
-- ============================================================
SHOW GLOBAL BINDING FOR
  SELECT * FROM t_spm_test WHERE status = ? AND city = ? ORDER BY created_at DESC LIMIT ?;

-- ============================================================
-- 4. EXPLAIN 验证：执行计划应该走 idx_status 索引
-- ============================================================
EXPLAIN SELECT * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;

-- ============================================================
-- 5. 实际执行（验证性能改善）
-- ============================================================
SELECT SQL_NO_CACHE * FROM t_spm_test
WHERE status = 1 AND city = 'Beijing'
ORDER BY created_at DESC
LIMIT 20;

-- ============================================================
-- 6. 查看 Binding 的状态信息
-- ============================================================
SELECT * FROM information_schema.bind_info
WHERE original_sql LIKE '%t_spm_test%'\G

-- ============================================================
-- 7. 删除 Binding（清理测试）
-- ============================================================
-- DROP GLOBAL BINDING FOR
--   SELECT * FROM t_spm_test WHERE status = 1 AND city = 'Beijing' ORDER BY created_at DESC LIMIT 20;
