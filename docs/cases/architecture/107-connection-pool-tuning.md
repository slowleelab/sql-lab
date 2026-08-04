# 数据库连接池调优：HikariCP / Druid 视角

<CaseMeta difficulty="⭐⭐⭐" category="架构级优化" versions="5.7 & 8.0" :tags="['连接池', 'HikariCP', 'Druid', 'max_connections', 'wait_timeout', '应用层优化']" />

## 2000失败：新连接申请失败
应用启动后运行正常，但**高峰时段**（如大促）数据库连接数飙到 2000+（超过 `max_connections=1000`），新连接申请失败，应用开始报 "Too many connections"。运维紧急重启后恢复，但几小时后再次发生。

监控显示：
- MySQL 端 `Threads_connected=2000`，`Max_used_connections=2100`
- 应用端每个 Tomcat 节点维持 50 个空闲连接，20 个节点 = 1000 个空闲连接
- 高峰时**业务 SQL 并发 800**，但同时**大量慢查询**占住连接不释放

```sql
-- MySQL 端状态
SHOW STATUS LIKE 'Threads_connected';   -- 2000
SHOW STATUS LIKE 'Max_used_connections'; -- 2100
SHOW STATUS LIKE 'Slow_queries';         -- 1000/sec（！）
```

::: warning 真实场景
"数据库连接不够用"是 Java 应用最常见的性能问题之一。根因往往是**连接池配置错误**或**应用层慢 SQL 拖垮连接**。盲目增加 `max_connections` 不能解决问题——MySQL 每连接消耗 ~10MB 内存，2000 连接 = 20GB，光连接就吃光服务器内存。本案例从**应用层连接池 + 数据库 max_connections 双向调优**给出方案。
:::

## 问题分析

### bad.sql — 配置错误示范

```sql
-- bad 配置: MySQL 端 max_connections 设置过小
SHOW VARIABLES LIKE 'max_connections';
-- max_connections = 200    ← 太小！20 个应用节点 × 50 池大小 = 1000

-- bad 配置: 应用端连接池无上限
-- HikariCP 默认 maximumPoolSize=10，但很多团队误配为 100+
-- dataSource.setMaximumPoolSize(100);  ← 单节点 100，20 节点 2000

-- 慢查询占住连接
SHOW PROCESSLIST;
-- Id=12345 User=app Host:10.0.0.5:54321 db=sql_treasure Command=Sleep Time=300
-- ↑ Sleep 300 秒——连接没释放！
```

### 三个常见根因

| 根因 | 表现 | 解决方案 |
|------|------|---------|
| **MySQL `max_connections` 太小** | 应用报 "Too many connections" | 适度调大（如 1000），但不能过大 |
| **应用连接池配置过大** | `Threads_connected` 持续接近 max | 调小 `maximumPoolSize` |
| **慢 SQL 占住连接不释放** | `Sleep` 状态连接多 | 优化 SQL + 调小 `wait_timeout` + 连接池检测 |

## 优化方案

### good.sql — 双端调优

```sql
-- ── MySQL 端调优 ──

-- 1. 适度调大 max_connections（按内存算：1000 连接 × 10MB = 10GB）
SET GLOBAL max_connections = 1000;
-- 配合 innodb_buffer_pool_size 调整（连接占用 ~10MB/个，buffer pool 通常占总内存 50-70%）

-- 2. 缩短 wait_timeout，自动回收空闲连接（默认 8 小时太长）
SET GLOBAL wait_timeout = 300;       -- 空闲 5 分钟自动断开
SET GLOBAL interactive_timeout = 300;

-- 3. 监控连接状态
SHOW STATUS LIKE 'Threads_connected';
SHOW STATUS LIKE 'Threads_running';  -- 真正在执行的（应 < CPU 核数 × 2）
SHOW STATUS LIKE 'Max_used_connections';
```

```yaml
# ── 应用端连接池调优（HikariCP）──
# application.yml
spring:
  datasource:
    type: com.zaxxer.hikari.HikariDataSource
    hikari:
      # 核心调优（按"CPU 核数 × 2 + 磁盘数"经验公式）
      maximum-pool-size: 20        # 单节点最大连接
      minimum-idle: 5              # 维持最小空闲
      
      # 超时控制（关键）
      connection-timeout: 3000     # 3s 拿不到连接就报错（不阻塞业务）
      idle-timeout: 300000         # 5 分钟空闲连接回收
      max-lifetime: 1800000        # 30 分钟强制重建（避 MySQL wait_timeout）
      
      # 连接健康检查
      validation-timeout: 2000
      connection-test-query: "SELECT 1"
      # 或更好: connection-init-sql: "SET SESSION transaction_isolation = 'READ-COMMITTED'"
      
      # 泄漏检测（开发环境）
      leak-detection-threshold: 10000  # 10s 还没关闭的连接报警
```

```yaml
# ── Druid 替代方案（阿里系常用）──
spring:
  datasource:
    druid:
      initial-size: 5
      min-idle: 5
      max-active: 20                # 同 HikariCP
      max-wait: 3000                # 拿连接超时
      
      # 监控（比 HikariCP 强）
      filters: stat,wall,slf4j
      filter.stat.log-slow-sql: true
      filter.stat.slow-sql-millis: 200
      
      # 连接保活
      validation-query: SELECT 1
      test-while-idle: true
      time-between-eviction-runs-millis: 60000
```

### 原理

**连接池工作模型**：

```
应用 (Tomcat Node × 20)        MySQL Server
┌─────────────────────┐        ┌─────────────────┐
│ Connection Pool     │  TCP   │ Connections     │
│ ┌─────┐ ┌─────┐   │◀──────▶│ 200-1000 个     │
│ │ C1  │ │ C2  │   │  ...   │                 │
│ └─────┘ └─────┘   │        │ 活跃 ~ 50-200   │
│ size: 20           │        │ 空闲 ~ 100      │
└─────────────────────┘        └─────────────────┘
       ▲                              ▲
       │                              │
   maximumPoolSize            max_connections
   决定应用要多少           决定 MySQL 能接多少
```

**关键调优公式**（Percona / HikariCP 官方推荐）：

```
connections = ((core_count * 2) + effective_spindle_count)
```

| 服务器 | CPU 核数 | 磁盘（NVMe） | 推荐单节点池大小 | 推荐 max_connections（20 节点） |
|--------|---------|------------|----------------|-------------------------------|
| 4 核 | 4 | 1 | 9 | 180 |
| 8 核 | 8 | 2 | 18 | 360 |
| 16 核 | 16 | 4 | 36 | 720 |
| 32 核 | 32 | 8 | 72 | 1440 |

**经验法则**：

- `maximumPoolSize = 2 × CPU 核数`（避免上下文切换）
- 总量 = `maximumPoolSize × 应用节点数 × 1.2`（冗余 20%）
- MySQL `max_connections = 上述总量 + 预留`（如 50 个给 DBA/监控）

### 对比

| 指标 | bad (默认配置) | good (调优后) |
|------|---------------|--------------|
| `max_connections` | 200 | 1000 |
| Hikari `maximum-pool-size` | 100 | 20 |
| `wait_timeout` | 28800 (8h) | 300 (5min) |
| `connection-timeout` | 30s | 3s |
| `Threads_connected` 高峰 | 2000（爆） | 350（健康） |
| 业务报错 "Too many connections" | 频繁 | 0 |
| 应用 GC 压力 | 高（连接对象堆积） | 低 |
| 慢查询占连接 | 几百个 Sleep | 几十个 Sleep |

<ExplainCompare
  :bad="{ type: '默认', key: 'max_conn=200, pool=100', rows: '2000连接', Extra: '高峰期爆连接，GC 抖动' }"
  :good="{ type: '调优', key: 'max_conn=1000, pool=20', rows: '350连接', Extra: '健康水位，慢查询自动回收' }"
  improvement="连接爆满归零，应用 P99 延迟从 2s 降到 200ms"
/>

## 避坑指南

::: warning 注意事项

1. **不要盲目调大 `max_connections`**。每连接占 ~10MB 内存，5000 连接 = 50GB 内存。MySQL 是单进程模型，连接数过多会显著降低调度效率。`max_connections` 应按内存和 CPU 核数合理计算。

2. **`Sleep` 状态的连接也是连接**。`SHOW PROCESSLIST` 中 `Command=Sleep` 的连接仍占用 `max_connections` 配额。`wait_timeout` 调小可让 MySQL 服务端主动断开，但**更好的方案是连接池层**控制（`idle-timeout`）。

3. **连接池不是越大越好**。每个连接有内存开销，且增加数据库上下文切换。一般 8-32 即可。MySQL 8.0 + HikariCP 配合 8 核机器，pool=16 通常最优。

4. **`maxLifetime` 必须小于 MySQL `wait_timeout`**。否则应用以为连接可用，实际 MySQL 已单方面断开，导致第一次查询报错。HikariCP 默认 30 分钟，MySQL 调成 5 分钟，OK。

5. **DNS 反查**：MySQL 5.7 默认开启 `skip_name_resolve`，每次连接会反查 IP 对应主机名。务必在 `my.cnf` 中设置 `skip-name-resolve`，避免连接慢。

6. **生产环境禁用 `useUnicode=true&characterEncoding=utf8`**。直接连接 MySQL 不需要客户端 charset 参数（驱动会自动协商）。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 默认 `max_connections` | 151 | 151 |
| 默认 `wait_timeout` | 28800 (8h) | 28800 (8h) |
| 连接认证性能 | caching_sha2_password 需 RSA | 5.7 用 mysql_native_password |
| 线程池插件 | 社区版无（MariaDB/Percona 有） | 同 5.7 |
| Performance Schema 连接监控 | 完善 | 完善 + `memory_summary_by_thread_by_event_name` |
| `show_compatibility_56` | 默认 ON | 8.0.1 起默认 OFF（部分状态变量需用 Performance Schema） |

::: tip 推荐实践
- **MySQL 端**：`max_connections=1000`, `wait_timeout=300`, `skip-name-resolve=ON`, `thread_cache_size=50`
- **HikariCP**：`maximum-pool-size=CPU*2`, `max-lifetime=1800000`, `connection-timeout=3000`
- **Druid**：开启 `stat` 监控 + 慢 SQL 记录
- **监控**：`Threads_connected` / `Threads_running` / `Max_used_connections` 三大指标报警
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 107-connection-pool-tuning

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 107-connection-pool-tuning --ver 5.7

# 模拟高并发连接
./scripts/run-case.sh 107-connection-pool-tuning --stress 50
```
