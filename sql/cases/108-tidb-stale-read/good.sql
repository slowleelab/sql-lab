-- good.sql: 使用 Stale Read

-- 1. 会话级 Stale Read（容忍5秒延迟）
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;
SET SESSION tidb_read_staleness = '';

-- 2. SQL 语句级：AS OF TIMESTAMP 语法
-- 读取 10 秒前的快照
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale
AS OF TIMESTAMP TIMESTAMPADD(SECOND, -10, NOW());

-- 3. 精确时间点读取（审计场景）
SET @snapshot_ts = '2026-07-01 00:00:00';
-- 读取指定时间点的数据快照
SELECT id, item, qty, price FROM t_stale
AS OF TIMESTAMP @snapshot_ts
ORDER BY id LIMIT 20;

-- 4. Stale Read + Follower Read 组合
SET SESSION tidb_replica_read = 'follower';
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;

-- 5. 验证 Stale Read 不阻塞写（从监控角度说明）
-- 开启一个长事务读取（Stale Read）的同时，
-- 另一个会话可以正常写入——两者不会互相阻塞

-- 6. 对比三种读取方式
SELECT 'Strong Read' AS mode, 'Leader' AS target, '0ms' AS staleness, '可能被写阻塞' AS blocked
UNION ALL
SELECT 'Follower Read', 'Follower', '~100ms (Raft apply)', '不阻塞但可能有延迟'
UNION ALL
SELECT 'Stale Read', 'Leader/Follower', '自定义(秒级)', '不阻塞写入'
;
