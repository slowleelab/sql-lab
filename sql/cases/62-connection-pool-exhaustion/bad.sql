-- bad.sql: 连接池与 max_connections 耗尽场景
--
-- 场景描述:
--   生产环境突发大量 "Too many connections" 报错，新连接全部被拒绝。
--   根因：一批慢 SQL（全表扫描）长时间占用连接不释放，连接池被打满，
--   新业务请求拿不到连接，级联导致整个服务不可用。
--
-- 诊断流程:
--   1. 确认报错 -> 2. SHOW PROCESSLIST 看连接状态 -> 3. SHOW STATUS 看连接数
--   -> 4. performance_schema 定位占用连接的具体线程和 SQL

-- ============================================================
-- 1. 故障现象: 新连接被拒绝
-- ============================================================
-- 应用日志报错（模拟）:
--   ERROR 1040 (HY000): Too many connections
--   ERROR 1040 (HY000): Too many connections
--   ERROR 1040 (HY000): Too many connections
--
-- 此时所有新连接（包括业务、监控、人工排查）都无法连入，
-- 只有持有 SUPER/CONNECTION_ADMIN 权限的账号还能建立 1 个额外连接。

-- ============================================================
-- 2. 慢 SQL（罪魁祸首）: 全表扫描，长时间占用连接
-- ============================================================
-- user_id 无索引，10 万行全表扫描，单次耗时数百毫秒
-- 高并发下大量连接同时执行此 SQL，连接迅速被占满
SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
-- 无索引 -> 全表扫描 -> 慢 -> 连接长时间不释放 -> 连接耗尽

-- ============================================================
-- 3. 诊断命令一: SHOW PROCESSLIST 查看当前所有连接状态
-- ============================================================
-- 故障时执行（需用预留的 SUPER 连接），典型输出（模拟）:
--   +----+------+-----------------+------+---------+------+------------+---------------------------------------------------+
--   |Id  |User  |Host             |db    |Command  |Time  |State      |Info                                               |
--   +----+------+-----------------+------+---------+------+------------+---------------------------------------------------+
--   |  1 |app   |10.0.0.11:39201  |prod  |Query    |  312 |Sending data|SELECT ... FROM t_conn_test WHERE user_id=7321 ...  |
--   |  2 |app   |10.0.0.12:41088  |prod  |Query    |  298 |Sending data|SELECT ... FROM t_conn_test WHERE user_id=7321 ...  |
--   |  3 |app   |10.0.0.11:39455  |prod  |Query    |  287 |Sending data|SELECT ... FROM t_conn_test WHERE user_id=7321 ...  |
--   | .. | ..   | ..              | ..   | ..      |  ..  | ..         | ..                                                |
--   |198 |app   |10.0.0.15:38812  |prod  |Query    |  120 |Sending data|SELECT ... FROM t_conn_test WHERE user_id=7321 ...  |
--   |199 |app   |10.0.0.16:40021  |prod  |Sleep    |   15 |            |NULL                                               |
--   |200 |app   |10.0.0.16:40130  |prod  |Sleep    |   42 |            |NULL                                               |
--   |201 |dba   |127.0.0.1:50123  |NULL  |Query    |    0 |starting   |SHOW PROCESSLIST                                   |
--   +----+------+-----------------+------+---------+------+------------+---------------------------------------------------+
--
-- 关键信号:
--   - Time 列大量 100~300 秒，说明连接长时间被占用
--   - State 全是 "Sending data"，说明在执行慢查询
--   - Info 全是同一条 user_id 查询，定位到罪魁 SQL
SHOW PROCESSLIST;
-- 等价于: SELECT * FROM information_schema.PROCESSLIST;（可做过滤）

-- 过滤出执行时间超过 60 秒的连接，快速锁定问题线程
SELECT id, user, host, db, command, time, state, LEFT(info, 80) AS sql_snippet
FROM information_schema.PROCESSLIST
WHERE command <> 'Sleep' AND time > 60
ORDER BY time DESC;

-- ============================================================
-- 4. 诊断命令二: SHOW STATUS 查看连接数水位
-- ============================================================
SHOW STATUS LIKE 'Threads%';
-- 模拟输出（max_connections=200，已耗尽）:
--   +-------------------+-------+
--   | Variable_name     | Value |
--   +-------------------+-------+
--   | Threads_cached    | 0     |   <- 线程缓存已空，每次新建线程
--   | Threads_connected | 200   |   <- 已连接数 = max_connections，已满
--   | Threads_created   | 8421  |   <- 累计创建线程数过高，说明频繁建连
--   | Threads_running   | 168   |   <- 活跃线程 168，几乎全在跑慢 SQL
--   +-------------------+-------+

-- 连接使用率 = Threads_connected / max_connections
-- 告警阈值: 超过 80% 应告警，达到 100% 即拒绝新连接
SHOW VARIABLES LIKE 'max_connections';
-- max_connections = 200

SELECT @@max_connections AS max_conn,
       VARIABLE_VALUE AS threads_connected,
       ROUND(VARIABLE_VALUE / @@max_connections * 100, 1) AS usage_pct
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Threads_connected';
-- usage_pct = 100.0 -> 连接已耗尽

-- ============================================================
-- 5. 诊断命令三: performance_schema 定位占用连接的线程
-- ============================================================
-- 查看每个连接的线程状态、当前执行的 SQL、已执行时长
SELECT
    t.thread_id,
    t.processlist_id AS conn_id,
    t.processlist_user AS user,
    t.processlist_host AS host,
    t.processlist_db AS db,
    t.processlist_command AS command,
    t.processlist_time AS time_sec,
    t.processlist_state AS state,
    t.processlist_info AS current_sql
FROM performance_schema.threads t
WHERE t.processlist_id IS NOT NULL
  AND t.processlist_command = 'Query'
ORDER BY t.processlist_time DESC
LIMIT 10;
-- 输出定位到 thread_id 及其正在执行的慢 SQL

-- 统计按 SQL 模式分组的连接数（找出哪类 SQL 占用了最多连接）
-- 8.0: performance_schema.events_statements_summary_by_digest
SELECT
    DIGEST_TEXT AS sql_pattern,
    COUNT_STAR AS exec_count,
    SUM_TIMER_WAIT / 1000000000 AS total_ms,
    AVG_TIMER_WAIT / 1000000000 AS avg_ms,
    CURRENT_SCHEMA
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%t_conn_test%'
ORDER BY COUNT_STAR DESC
LIMIT 5;
