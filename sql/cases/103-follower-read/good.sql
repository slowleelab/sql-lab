-- good.sql: 启用 Follower Read 将读取分散到 Follower 副本

-- 1. 会话级启用 Follower Read
SET SESSION tidb_replica_read = 'follower';

-- 2. 查看设置
SHOW VARIABLES LIKE 'tidb_replica_read';

-- 3. 同样查询走 Follower（实际分布取决于 Region 调度）
SELECT city, COUNT(*) AS cnt, AVG(score) AS avg_score
FROM t_follower
GROUP BY city;

-- 4. SQL Hint 方式：单条查询指定从 follower 读
SELECT /*+ READ_FROM_STORAGE(TIFLASH[t_follower]) */ city, AVG(score)
FROM t_follower GROUP BY city;

-- 5. Stale Read（有界延迟，进一步降低 Leader 压力）
-- 容忍 5 秒陈旧数据，但仍保证 snapshot consistency
SET SESSION tidb_read_staleness = -5;
SELECT city, COUNT(*), AVG(score) FROM t_follower GROUP BY city;
SET SESSION tidb_read_staleness = '';

-- 6. 对比三种模式
SELECT 'leader' AS mode, 'TIPrefixIndex.value' AS key FROM mysql.tidb;
