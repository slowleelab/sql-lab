# 通用慢查询排查与锁等待定位

<CaseMeta difficulty="⭐⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['performance_schema', 'sys.session', '锁等待', '慢查询', 'sys.schema']" />

## 场景痛点

线上告警"数据库 QPS 下降 50%"，但没收到具体慢 SQL 邮件。`SHOW PROCESSLIST` 看到一堆 "Waiting for table metadata lock" 或 "Waiting for row lock"。DBA 拿不到是谁、哪个 SQL、锁了多久。

```sql
-- 看到一堆 lock 等待但不知道根源
SHOW FULL PROCESSLIST;
-- 100 个连接，60 个 Waiting for lock
-- 看到 "Waiting for table metadata lock" 但不知道哪个会话持锁

-- 单条 SHOW PROCESSLIST 信息有限
-- 不知道：等待什么锁？持锁人是谁？SQL 是什么？事务多久了？
```

`SHOW PROCESSLIST` 信息太薄，定位慢查询/锁等待需要 `performance_schema` 和 `sys schema` 的系统视图。

::: warning 真实场景
某系统上线后 DDL `ALTER TABLE` 卡住 5 分钟不返回，所有 DML 都"Waiting for table metadata lock"。DBA 用 `sys.schema_table_lock_waits` 一查：发现 3 个未提交事务的连接持锁，kill 掉后 DDL 立即返回。**10 分钟定位 → 1 秒定位**。
:::

## 问题分析

### bad.sql — 仅看 PROCESSLIST 无法定位

```sql
-- bad.sql: SHOW PROCESSLIST 信息有限
SHOW FULL PROCESSLIST;
-- 看到：
-- | Id | User | Command | Time | State                      | Info
-- | 5  | app  | Sleep   | 120  |                            | NULL
-- | 6  | app  | Query   | 5    | Waiting for table metadata | ALTER TABLE t_order ...
-- | 7  | app  | Query   | 2    | Waiting for table metadata | SELECT * FROM t_order ...
-- ...
-- 看到等待，但不知道：
--   - 谁持锁？→ Id=5 是 Sleep，但它是真正的元凶
--   - 持锁人 SQL 是什么？→ Sleep 连接的 INFO 是 NULL
--   - 持锁多久了？→ Id=5 已经 Sleep 120s
```

### 观察结果

排查耗时对比：

| 排查方法 | 平均耗时 | 信息量 |
|---------|---------|--------|
| `SHOW PROCESSLIST` 肉眼找 | 10 分钟 | 弱 |
| `INFORMATION_SCHEMA.PROCESSLIST` | 5 分钟 | 中 |
| `performance_schema.events_statements_history` | 2 分钟 | 中（需历史）|
| **`sys.session` / `sys.innodb_lock_waits`** | **30 秒** | **强** |
| `MySQL 8.0` `EXPLAIN ANALYZE` | 5 秒 | 强 |

### 为什么慢（排查难）

`SHOW PROCESSLIST` 限制：
- **Sleep 连接无 INFO**（应用层连接池常态）
- **看不到阻塞关系**（谁是凶手，谁是受害者）
- **看不到锁类型**（MDL 锁 vs 行锁 vs 间隙锁）
- **看不到历史**（已经跑完的慢 SQL 看不到）

`performance_schema` 优势：
- 记录**所有事件**（statement / stage / wait / transaction / lock）
- 记录**阻塞关系**（`events_waits_current.parent_event_id`）
- 记录**历史**（`events_statements_history` 默认保留 10 条/连接）

`sys schema` 优势：
- 把 performance_schema 的复杂 join 封装成**易读视图**
- 直接查 `sys.innodb_lock_waits` / `sys.schema_table_lock_waits` / `sys.session`
- 8.0 内置，5.7 需 `mysql sys` 库导入

## 优化方案

### good.sql — 用 sys schema 快速定位

```sql
-- 1. 当前正在执行的 SQL 和对应线程（最常用）
SELECT * FROM sys.session
WHERE conn_id != CONNECTION_ID()
  AND command != 'Sleep'
ORDER BY time DESC;
-- 显示：thread_id, conn_id, user, db, command, time, state, current_statement
-- 还能看到: statement_latency, lock_latency, rows_examined 等

-- 2. 锁等待（5.7+ / 8.0）
-- 找出谁在等谁
SELECT * FROM sys.innodb_lock_waits\G
-- 返回：
-- waiting_trx_id, waiting_thread, waiting_query,
-- blocking_trx_id, blocking_thread, blocking_query

-- 3. 表元数据锁等待（MDL）
SELECT * FROM sys.schema_table_lock_waits\G
-- 返回：waiting_thread, waiting_query, blocking_thread, blocking_query

-- 4. 找出执行时间最长的前 10 个 SQL（实时）
SELECT thread_id, processlist_id, processlist_user, processlist_host,
       processlist_db, processlist_command, processlist_time,
       processlist_state, processlist_info
FROM performance_schema.threads
WHERE processlist_command = 'Query'
  AND processlist_info IS NOT NULL
ORDER BY processlist_time DESC
LIMIT 10;

-- 5. 找出最近执行过的慢 SQL（历史，需要先开启 history）
SELECT thread_id, event_name, timer_wait/1e9 AS duration_sec,
       sql_text
FROM performance_schema.events_statements_history
WHERE timer_wait > 1e9  -- 大于 1s 的 SQL
ORDER BY timer_start DESC
LIMIT 20;

-- 6. 8.0 实时 EXPLAIN（无需真正执行，看执行计划）
EXPLAIN SELECT * FROM t_order WHERE user_id = 12345;

-- 7. 8.0 EXPLAIN ANALYZE（实际执行并显示真实耗时）
EXPLAIN ANALYZE SELECT * FROM t_order WHERE user_id = 12345;
-- -> Index lookup on t_order using idx_user (user_id=12345)  (cost=2.5 rows=1) (actual time=0.8..0.8 rows=1)
-- 真实耗时一目了然

-- 8. 杀掉阻塞源
-- 查 sys.innodb_lock_waits 拿到 blocking_pid 后：
KILL <blocking_pid>;
```

启用 `performance_schema` 完整记录（`my.cnf`）：

```ini
[mysqld]
# 开启 performance_schema
performance_schema = ON

# 完整事件记录（默认已经够用，生产可调高）
performance_schema_max_digest_length = 4096
performance_schema_max_sql_text_length = 4096

# 5.7 需导入 sys schema（5.7.7+ 默认已有）
# 8.0 默认有 sys schema

# 启用 statement digests（聚合相似 SQL）
performance_schema_events_statements_history_long_size = 1000
```

### 原理

**performance_schema 三层架构**：

```
performance_schema
  ├── threads（所有线程快照）
  ├── events_waits_current（当前等待）
  ├── events_statements_current（当前 SQL）
  ├── events_statements_history（最近 10 条/线程）
  ├── events_statements_history_long（全实例最近 1000 条聚合）
  ├── setup_instruments（采集项开关）
  └── setup_consumers（采集消费者）
```

**sys schema 视图封装**：

| 视图 | 用途 | 等价 SQL |
|------|------|---------|
| `sys.session` | 当前连接 | `SELECT ... FROM performance_schema.threads` + `events_statements_current` |
| `sys.innodb_lock_waits` | InnoDB 行锁等待关系 | `performance_schema.data_locks` + `data_lock_waits` |
| `sys.schema_table_lock_waits` | MDL 锁等待关系 | `metadata_locks` + `metadata_lock_info` |
| `sys.host_summary` | 按 host 统计 QPS / 慢查询 | 聚合 `events_statements_summary_by_host` |
| `sys.io_global_by_file_by_bytes` | IO 热点 | `file_summary_by_instance` |
| `sys.statements_with_full_table_scans` | 全表扫描 SQL | `events_statements_summary_by_digest WHERE no_index_used` |
| `sys.statements_with_runtimes_in_95th_percentile` | P95 慢 SQL | `events_statements_summary_by_digest ORDER BY avg_timer_wait` |

**`EXPLAIN ANALYZE`（8.0+）**：
- 真正执行 SQL，附加每个算子的实际耗时
- 比 `EXPLAIN` 更准确（用 `cost=2.5 rows=1` 是估算，`actual time=0.8..0.8 rows=1` 是实际）
- 适合排查"为什么这条 SQL 慢"但不适合排查"为什么这条 SQL 触发了 N 万行扫描"（会真跑）

### 对比

| | bad (SHOW PROCESSLIST) | good (sys schema) |
|---|---|---|
| 平均定位时间 | 10 min | **30s** |
| 看到阻塞关系 | ❌ | ✅ |
| 看到锁类型 | ❌ | ✅ |
| 看到 Sleep 连接的"历史 SQL" | ❌ | ✅ `events_statements_history` |
| 看到执行计划真实耗时 | ❌ | ✅ `EXPLAIN ANALYZE` |
| 看到全表扫描 SQL | ❌ | ✅ `sys.statements_with_full_table_scans` |

实测故障场景（DDL 卡死 5 分钟）：

| 排查方式 | 耗时 |
|---------|------|
| SHOW PROCESSLIST 肉眼 | 10 min |
| `sys.session` + `sys.schema_table_lock_waits` | **30s** |
| `performance_schema.metadata_locks` 直接查 | 2 min |

<ExplainCompare
  :bad="{ type: '排查方法', key: 'SHOW PROCESSLIST', rows: '定位 10min', Extra: '无阻塞关系' }"
  :good="{ type: '排查方法', key: 'sys schema + EXPLAIN ANALYZE', rows: '定位 30s', Extra: '完整阻塞关系 + 真实耗时' }"
  improvement="排查效率提升 20 倍"
/>

## 避坑指南

::: warning 注意事项

1. **`performance_schema` 本身有性能开销**。默认配置下开销约 1-3%，但开启所有 instrument 可达 5-10%。建议保留默认配置，按需开启具体 instrument。

2. **`events_statements_history` 默认只保留 10 条**。如果你排查的 SQL 几秒就跑完，可能已经被踢出 history。需调高 `performance_schema_events_statements_history_size` 或开启 `events_statements_history_long`（默认 1000 条，但占空间）。

3. **`sys.innodb_lock_waits` 在 8.0 重命名**。8.0 之前叫 `sys.innodb_lock_waits`，8.0+ 仍叫此名但内部实现换了。`performance_schema.data_locks` + `data_lock_waits` 是 8.0 官方推荐。

4. **`EXPLAIN ANALYZE` 真的会执行 SQL**。在生产环境用 `EXPLAIN ANALYZE DELETE/UPDATE` 是危险的，可能锁大量行。建议先 `EXPLAIN` 看计划，再用 `EXPLAIN ANALYZE` 在低峰或非 DML 上。

5. **`KILL` 命令需要 PROCESS 权限**。让应用层用专用 DBA 账号连数据库，避免权限不足无法 kill。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `performance_schema` 默认开启 | ✅ 5.7.8+ | ✅ |
| `sys schema` 默认导入 | ✅ 5.7.7+ | ✅ |
| `sys.innodb_lock_waits` | ✅ 旧实现 | ✅ 重写为 `data_locks`+`data_lock_waits` |
| `EXPLAIN ANALYZE` | ❌ | ✅ 8.0.18+ |
| `EXPLAIN FORMAT=TREE` | ❌ | ✅ 8.0.16+ |
| `performance_schema.data_locks` | ❌ | ✅ 8.0+ |
| `sys.statements_with_full_table_scans` | ✅ | ✅ |
| `events_statements_history_long` | 默认 1000 | 默认 1000 |

::: tip 慢查询排查 SOP
1. **接收告警**：QPS 下降 / RT 飙升 / 磁盘 IO 高
2. **`SELECT * FROM sys.session WHERE command='Query' ORDER BY time DESC LIMIT 10`**：看正在执行的慢 SQL
3. **`SELECT * FROM sys.innodb_lock_waits`**：看锁等待关系
4. **`SELECT * FROM sys.schema_table_lock_waits`**：看 MDL 锁
5. **`EXPLAIN ANALYZE <慢SQL>`**：看真实执行计划
6. **`SELECT * FROM sys.statements_with_full_table_scans`**：看历史全表扫描
7. **`KILL <blocking_pid>`** 或应用层修复
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 112-slow-query-diagnosis

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 112-slow-query-diagnosis --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 112-slow-query-diagnosis --no-seed
```
