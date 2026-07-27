# 连接池与 max_connections 耗尽诊断

<CaseMeta difficulty="⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['max_connections', '连接池', 'Too many connections', 'Threads_connected', 'PROCESSLIST']" />

## 场景痛点

大促开始 10 分钟，监控红灯全亮：应用日志疯狂报错 `ERROR 1040 (HY000): Too many connections`，所有新连接被数据库拒绝，接口大面积超时，整个服务几乎不可用。DBA 登入排查发现 `max_connections=200` 已被占满，168 个线程同时在跑同一条慢 SQL。

```sql
-- 罪魁 SQL：user_id 无索引，10 万行全表扫描
SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
```

这条 SQL 单次执行 150~300ms，高并发下大量连接同时执行，连接被长时间占用，连接池瞬间打满。

::: warning 真实场景
"Too many connections" 是生产事故的高频元凶。根因往往不是 max_connections 设得太小，而是**慢 SQL 占用连接不释放**。一条缺索引的全表扫描 SQL，在高并发下能把数百个连接"锁住"数分钟，级联拖垮整个服务。真正的解法是治慢 SQL + 合理配置连接池，而不是无脑调大 max_connections。
:::

## 问题分析

### bad.sql

```sql
-- 慢 SQL：user_id 无索引，全表扫描，单次 150~300ms
SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
```

### EXPLAIN 结果

```
+----+-------------+-------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
| id | select_type | table       | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra                       |
+----+-------------+-------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
|  1 | SIMPLE      | t_conn_test | ALL  | NULL          | NULL | NULL    | NULL | 100120 |    10.00 | Using where; Using filesort |
+----+-------------+-------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
```

全表扫描 10 万行 + filesort，单次 150~300ms。

### 诊断：SHOW PROCESSLIST 看连接状态

```sql
-- 故障时执行，典型输出：大量连接被同一条慢 SQL 占用
SHOW PROCESSLIST;
```

```
+-----+------+-----------------+------+---------+------+-------------+----------------------------------------------------------+
| Id  | User | Host            | db   | Command | Time | State       | Info                                                     |
+-----+------+-----------------+------+---------+------+-------------+----------------------------------------------------------+
|   1 | app  | 10.0.0.11:39201 | prod | Query   |  312 | Sending data| SELECT ... FROM t_conn_test WHERE user_id=7321 ...        |
|   2 | app  | 10.0.0.12:41088 | prod | Query   |  298 | Sending data| SELECT ... FROM t_conn_test WHERE user_id=7321 ...        |
| ... | ...  | ...             | ...  | ...     |  ... | ...         | ...                                                      |
| 198 | app  | 10.0.0.15:38812 | prod | Query   |  120 | Sending data| SELECT ... FROM t_conn_test WHERE user_id=7321 ...        |
| 199 | app  | 10.0.0.16:40021 | prod | Sleep   |   15 |             | NULL                                                     |
| 200 | app  | 10.0.0.16:40130 | prod | Sleep   |   42 |             | NULL                                                     |
| 201 | dba  | 127.0.0.1:50123 | NULL | Query   |    0 | starting    | SHOW PROCESSLIST                                          |
+-----+------+-----------------+------+---------+------+-------------+----------------------------------------------------------+
```

关键信号：Time 列 100~312 秒、State 全是 "Sending data"、Info 高度重复（锁定罪魁 SQL）。

```sql
-- 过滤执行超过 60 秒的连接，快速锁定问题线程
SELECT id, user, host, db, command, time, state, LEFT(info, 80) AS sql_snippet
FROM information_schema.PROCESSLIST
WHERE command <> 'Sleep' AND time > 60
ORDER BY time DESC;
```

### 诊断：SHOW STATUS 看连接水位

```sql
SHOW STATUS LIKE 'Threads%';
```

```
+-------------------+-------+
| Variable_name     | Value |
+-------------------+-------+
| Threads_cached    | 0     |   <- 线程缓存空
| Threads_connected | 200   |   <- 已达 max_connections 上限
| Threads_created   | 8421  |   <- 累计创建线程数异常高
| Threads_running   | 168   |   <- 168 个线程同时在跑慢 SQL
+-------------------+-------+
```

### 连接耗尽根因分析

```
1. 新 SQL 缺索引 -> 单次 150~300ms 全表扫描
2. 业务 QPS 1000，每秒 1000 个连接请求执行此慢 SQL
3. 单连接吞吐 = 1000ms/300ms ≈ 3 QPS/连接
4. 支撑 1000 QPS 需 ≈ 334 连接，但 max_connections=200
5. 连接被打满 -> 新请求拿不到连接 -> "Too many connections"
6. 应用连接池获取超时 -> 请求堆积 -> 线程池打满 -> 服务雪崩
```

三类常见根因：

| 根因 | PROCESSLIST 表现 | 本案例 |
|------|------------------|--------|
| 慢 SQL 占连接 | Time 高、State=Sending data、Info 重复 | ✅ 主因 |
| 连接泄漏 | State=Sleep、Info=NULL、连接不归还 | 部分（199/200） |
| 突发流量 | 短时间 connections 暴增 | 触发因素 |

### 诊断：performance_schema 定位占用连接的线程

```sql
-- 查看每个连接正在执行的 SQL 及其已执行时长
SELECT
    t.thread_id, t.processlist_id AS conn_id, t.processlist_user AS user,
    t.processlist_host AS host, t.processlist_time AS time_sec,
    t.processlist_state AS state, t.processlist_info AS current_sql
FROM performance_schema.threads t
WHERE t.processlist_id IS NOT NULL
  AND t.processlist_command = 'Query'
ORDER BY t.processlist_time DESC
LIMIT 10;
```

## 优化方案

### good.sql

```sql
-- 1. 对慢 SQL 建联合索引：过滤+排序都走索引，毫秒级返回
ALTER TABLE t_conn_test ADD INDEX idx_user_created (user_id, created_at);

SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
-- EXPLAIN: type=ref, key=idx_user_created, rows≈12, Backward index scan
```

### 建索引释放连接

联合索引 `(user_id, created_at)` 解决两个问题：

1. **user_id 等值查找走索引**：扫描行数从 10 万降到 12
2. **created_at 排序利用索引有序性**：消除 filesort（`Backward index scan`）

单次耗时从 150~300ms 降到 1ms 以内，连接快速释放，单连接吞吐从 ~3 QPS 提升到 ~1000 QPS。

### max_connections 调优

```sql
-- 8.0 运行时持久化
SET PERSIST max_connections = 500;
SET PERSIST wait_timeout = 600;          -- 空闲 10 分钟回收泄漏连接
SET PERSIST interactive_timeout = 600;
SET PERSIST thread_cache_size = 64;      -- 减少线程创建开销

-- 5.7: SET GLOBAL 后需手改 my.cnf 持久化
-- SET GLOBAL max_connections = 500;
```

### 连接池配置公式

```
连接池大小（HikariCP 官方推荐）:
  pool_size = (CPU 核心数 * 2) + 有效磁盘数
  实践经验: 单实例 10~20 足够

全局容量规划:
  max_connections = 应用实例数 * pool_size + 预留(20)
  示例: 10 实例 * 20 连接 + 20 预留 = 220 -> 设 250~300
```

::: tip 核心认知
更多连接 ≠ 更高吞吐。连接过多导致上下文切换开销增大，反而变慢。单实例连接池 10~20 通常足够支撑高并发。治本之策是让每条 SQL 快速返回、快速释放连接，而不是堆连接数。
:::

### kill 占用连接的慢查询

```sql
-- 找出执行超过 60 秒的慢查询连接
SELECT id, user, host, time, LEFT(info, 60) AS sql_snippet
FROM information_schema.PROCESSLIST
WHERE command = 'Query' AND time > 60
ORDER BY time DESC;

-- 紧急 kill 罪魁连接（id 来自 PROCESSLIST.Id）
KILL 198;
```

### 监控连接使用率

```sql
-- 核心监控指标：连接使用率
SELECT @@max_connections AS max_conn,
       VARIABLE_VALUE AS threads_connected,
       ROUND(VARIABLE_VALUE / @@max_connections * 100, 1) AS usage_pct
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Threads_connected';
-- 优化后: max_conn=500, threads_connected=85, usage_pct=17.0%

-- 连接来源 Top（定位哪个应用实例连接异常）
SELECT processlist_host AS host, COUNT(*) AS conn_count
FROM performance_schema.threads
WHERE processlist_id IS NOT NULL
GROUP BY processlist_host
ORDER BY conn_count DESC
LIMIT 10;
```

### 对比

| | bad.sql（耗尽） | good.sql（优化后） |
|---|---|---|
| type | ALL（全表扫描） | ref（索引查找） |
| 扫描行数 | 100,120 | 12 |
| 单次耗时 | 150~300 ms | < 1 ms |
| 单连接吞吐 | ~3 QPS | ~1000 QPS |
| Threads_connected | 200（100%） | 85（17%） |
| Threads_running | 168 | 12 |
| Too many connections | 频繁报错 | 消失 |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '100120', Extra: 'Using where; Using filesort - 全表扫描占连接 150~300ms' }"
  :good="{ type: 'ref', key: 'idx_user_created', rows: '12', Extra: 'Backward index scan - 1ms 返回，连接快速释放' }"
  improvement="扫描行数从 10 万降到 12，单次耗时缩短约 200 倍，连接使用率从 100% 降到 17%"
/>

## 避坑指南

::: warning 注意事项

1. **连接池大小要小**。单实例 10~20 足够。盲目调大连接池会让数据库更慢（上下文切换开销），而非更快。公式：`pool_size = (CPU核心数 * 2) + 磁盘数`。

2. **wait_timeout 必须与连接池 maxLifetime 配合**。连接池 maxLifetime 必须**小于** wait_timeout，否则服务端先踢掉连接，连接池里的"死连接"会报 `Communications link failure`。推荐 wait_timeout=600，maxLifetime=1800（30 分钟）。

3. **预留 SUPER 连接**。max_connections 之外，MySQL 为 SUPER/CONNECTION_ADMIN 权限账号额外预留 1 个连接，用于故障时紧急登入。不要把这个名额给应用账号。

4. **max_connections 不是越大越好**。过大导致内存占用增加（每连接约 256KB~1MB 线程栈）。500 是常见上限，1000+ 需评估内存。治本是治慢 SQL，而非堆连接数。

5. **监控 Threads_created 增速**。若持续快速增长，说明 thread_cache_size 太小，连接频繁创建销毁线程。调大 thread_cache_size（推荐 64）。

:::

::: tip 监控告警阈值
- 连接使用率 > 80% 告警，> 95% 紧急
- Threads_running > 50 告警，> 100 紧急
- 慢连接数（time>60s）> 10 告警，> 50 紧急
- Threads_created 增速 > 100/min 告警
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| SET PERSIST | ❌ 需改 my.cnf 重启 | ✅ 运行时持久化到 mysqld-auto.cnf |
| performance_schema.threads | 需手动开启 consumers | 默认更完善 |
| information_schema.PROCESSLIST | 5.7.9+ 支持过滤 | 支持 |
| 连接诊断原理 | 一致 | 一致 |

::: tip 8.0 改进
8.0 的 `SET PERSIST` 让参数调优无需改配置文件重启，故障应急时 `SET PERSIST max_connections=500` 即可立即生效并持久化。5.7 需 `SET GLOBAL` 临时生效 + 手改 my.cnf 持久化，操作更繁琐。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 62-connection-pool-exhaustion

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 62-connection-pool-exhaustion --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 62-connection-pool-exhaustion --no-seed
```
