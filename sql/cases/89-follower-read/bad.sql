-- bad.sql: 所有读取都打在 Leader 上（默认模式）
-- Leader 既处理写又处理所有读，CPU 和 IO 压力集中

-- 默认 follower read 关闭
SHOW VARIABLES LIKE 'tidb_replica_read';

-- 查看 Region 的 Leader/Follower 分布
SHOW TABLE t_follower REGIONS;

-- 高并发读：所有查询都路由到 Leader
SELECT city, COUNT(*) AS cnt, AVG(score) AS avg_score
FROM t_follower
GROUP BY city;
