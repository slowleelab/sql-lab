-- setup-good.sql: 准备批量插入测试环境
-- 可选: 调整 session 参数优化批量插入性能

-- 临时关闭 unique_checks 和 foreign_key_checks（仅适用于无外键约束的导入）
-- SET unique_checks = 0;
-- SET foreign_key_checks = 0;

-- 调整 innodb_flush_log_at_trx_commit（导入期间，降低 fsync 频率）
-- 0: 每秒刷盘（崩溃可能丢 1 秒数据）
-- 1: 每次提交刷盘（默认，最安全）
-- 2: 每次提交写 OS buffer，每秒刷盘（折中）
-- SET GLOBAL innodb_flush_log_at_trx_commit = 2;

-- 导入完成后恢复:
-- SET unique_checks = 1;
-- SET foreign_key_checks = 1;
-- SET GLOBAL innodb_flush_log_at_trx_commit = 1;

SELECT 'Session parameters for batch insert optimization (commented out by default).' AS info;
