-- setup-good.sql: 优化方案的前置准备（本案例无需额外 DDL，索引已在 schema 中）
-- 如 bad 场景演示的是无索引版本，可取消下方注释添加索引:
-- ALTER TABLE t_employee ADD KEY idx_manager (manager_id);
--
-- 本案例 bad/good 差异来自查询写法（函数包裹），无需 DDL 变更。
SELECT 'No DDL change needed. Optimization is query rewrite only.' AS info;
