-- good.sql: 连接耗尽的优化方案
--
-- 优化思路（四步走）:
--   1. 对慢 SQL 建索引，让它快速返回，释放连接
--   2. 调优 max_connections / wait_timeout / interactive_timeout
--   3. 应用侧连接池配置（大小计算公式）
--   4. kill 占用连接的慢查询 + 监控连接使用率

-- ============================================================
-- 1. 对慢 SQL 建索引：快速返回，释放连接
-- ============================================================
-- 原 bad SQL 按 user_id 过滤 + created_at 排序，全表扫描
-- 建联合索引 (user_id, created_at)，过滤+排序都走索引，毫秒级返回
ALTER TABLE t_conn_test
    ADD INDEX idx_user_created (user_id, created_at);

-- 优化后的查询：走索引，不再全表扫描，连接快速释放
SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
-- EXPLAIN: type=ref, key=idx_user_created, rows≈10, Using index condition
-- 单次耗时从数百毫秒降到 1ms 以内，连接占用时间缩短 100 倍

-- ============================================================
-- 2. max_connections 调优（全局参数，动态可改 + 写入配置文件持久化）
-- ============================================================
-- 查看当前值
SHOW VARIABLES LIKE 'max_connections';
-- 查看实际峰值使用，判断是否需要调大
SHOW STATUS LIKE 'Max_used_connections';
SHOW STATUS LIKE 'Threads_connected';

-- 临时调大（运行时生效，重启失效）：
SET GLOBAL max_connections = 500;

-- 持久化（8.0 推荐 SET PERSIST，写入 mysqld-auto.cnf，重启后保留）：
SET PERSIST max_connections = 500;

-- 5.7 持久化需手改 my.cnf 后重启：
--   [mysqld]
--   max_connections = 500

-- 限制空闲连接占用，避免连接泄漏导致耗尽
SHOW VARIABLES LIKE 'wait_timeout';        -- 非交互式连接空闲超时（秒）
SHOW VARIABLES LIKE 'interactive_timeout'; -- 交互式连接空闲超时（秒）
-- 推荐值：wait_timeout = 600（10 分钟），interactive_timeout = 600
-- 应用连接池有保活心跳时，wait_timeout 应略大于心跳间隔
SET PERSIST wait_timeout = 600;
SET PERSIST interactive_timeout = 600;

-- 5.7:
-- SET GLOBAL wait_timeout = 600;
-- SET GLOBAL interactive_timeout = 600;  -- 并写入 my.cnf 持久化

-- 线程缓存，避免频繁创建/销毁线程（减少 Threads_created 增长）
SHOW VARIABLES LIKE 'thread_cache_size';
SET PERSIST thread_cache_size = 64;
-- 5.7: SET GLOBAL thread_cache_size = 64;  -- 并写入 my.cnf

-- ============================================================
-- 3. 应用侧连接池配置最佳实践
-- ============================================================
-- 连接池大小计算公式（HikariCP 官方推荐）:
--   pool_size = (核心数 * 2) + 磁盘数
--   实际经验: 单实例连接池 10~20 足够支撑高并发，
--             "更多连接 = 更慢"（上下文切换开销）
--
-- 全局容量规划:
--   max_connections = 应用实例数 * 单实例连接池大小 + 监控/DBA 预留(20)
--   例: 10 个应用实例 * 20 连接 + 20 预留 = 220 -> 设 250~300 留余量
--
-- 各连接池关键配置:
--   HikariCP:   maximumPoolSize=20, connectionTimeout=3000(ms),
--               maxLifetime=1800000(30min, < wait_timeout), idleTimeout=600000
--   Druid:      maxActive=20, minIdle=5, maxWait=3000,
--               timeBetweenEvictionRunsMillis=60000,
--               minEvictableIdleTimeMillis=300000
--   关键: maxLifetime 必须小于 wait_timeout，否则连接被服务端踢掉后
--         连接池里的"死连接"会报 Communications link failure

-- ============================================================
-- 4. 紧急止血: kill 占用连接的慢查询
-- ============================================================
-- 找出执行时间超过 60 秒的慢查询连接
SELECT id, user, host, db, time, LEFT(info, 60) AS sql_snippet
FROM information_schema.PROCESSLIST
WHERE command = 'Query' AND time > 60
ORDER BY time DESC;
-- 示例输出:
--   +----+------+-----------------+------+-----+------------------------------------------------------------+
--   |id  |user  |host             |db    |time |sql_snippet                                                 |
--   +----+------+-----------------+------+-----+------------------------------------------------------------+
--   |198 |app   |10.0.0.15:38812  |prod  | 312 |SELECT id, user_id, data_value, created_at FROM t_conn_test |
--   +----+------+-----------------+------+-----+------------------------------------------------------------+

-- kill 掉罪魁连接（id 来自上面的 PROCESSLIST.Id 列）
KILL 198;
-- 批量 kill 执行时间超过 300 秒的慢查询（谨慎操作，确认无误后执行）
-- SELECT CONCAT('KILL ', id, ';') AS kill_sql
-- FROM information_schema.PROCESSLIST
-- WHERE command = 'Query' AND time > 300 AND user = 'app';

-- ============================================================
-- 5. 监控: performance_schema 持续监控连接使用率
-- ============================================================
-- 当前连接使用率（核心监控指标）
SELECT
    @@max_connections AS max_conn,
    VARIABLE_VALUE AS threads_connected,
    ROUND(VARIABLE_VALUE / @@max_connections * 100, 1) AS usage_pct
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Threads_connected';
-- 优化后（建索引+调参）:
--   max_conn=500, threads_connected=85, usage_pct=17.0%  <- 健康

-- 连接来源 Top（按 host 汇总，定位哪个应用实例连接数异常）
SELECT
    processlist_host AS host,
    COUNT(*) AS conn_count
FROM performance_schema.threads
WHERE processlist_id IS NOT NULL
GROUP BY processlist_host
ORDER BY conn_count DESC
LIMIT 10;

-- 历史峰值连接数（用于容量规划）
SHOW STATUS LIKE 'Max_used_connections';
-- 优化后峰值下降，说明慢 SQL 不再长期占用连接

-- 连接创建速率（Threads_created 增长过快说明 thread_cache_size 太小）
SHOW STATUS LIKE 'Threads_created';
