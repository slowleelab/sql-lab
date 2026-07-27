-- setup-good.sql: 设置合理的锁等待超时时间（5秒）
-- 默认 innodb_lock_wait_timeout=50 秒过长，调整为 5 秒快速失败
SET SESSION innodb_lock_wait_timeout = 5;
