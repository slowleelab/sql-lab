-- 一次性删除所有 DEBUG 日志（大事务，锁表，主从延迟）
-- 20 万行中约 70% 是 DEBUG，即约 14 万行一次性删除
-- 问题: 单条 DELETE 产生超大事务，长时间持有行锁，binlog 单条体积巨大
DELETE FROM t_log WHERE level = 0;
