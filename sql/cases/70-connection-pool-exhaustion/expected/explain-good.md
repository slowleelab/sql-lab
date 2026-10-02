# EXPLAIN 参考结果 - good.sql（建索引释放连接 + 连接池调优）

## MySQL 8.0（实测 8.0.46，t_conn_test 10 万行）

### 优化后 SQL 的 EXPLAIN

```sql
ALTER TABLE t_conn_test ADD INDEX idx_user_created (user_id, created_at);

SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
```

```
+----+-------------+-------------+------------+-------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
| id | select_type | table       | partitions | type  | possible_keys     | key               | key_len | ref   | rows | filtered | Extra                 |
+----+-------------+-------------+------------+-------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
|  1 | SIMPLE      | t_conn_test | NULL       | ref   | idx_user_created  | idx_user_created  | 8       | const |   12 |   100.00 | Backward index scan   |
+----+-------------+-------------+------------+-------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
```

## 关键改进

| 字段 | bad（无索引） | good（联合索引） | 分析 |
|------|--------------|-----------------|------|
| type | `ALL` | `ref` | 全表扫描 → 索引等值查找 |
| possible_keys | `NULL` | `idx_user_created` | 有可用索引 |
| key | `NULL` | `idx_user_created` | 命中联合索引 |
| rows | `100120` | `12` | 扫描行数从 10 万降到 12 |
| filtered | `10.00` | `100.00` | 100% 有效，无浪费 |
| Extra | `Using where; Using filesort` | `Backward index scan` | filesort 消除，索引天然有序 |
| 单次耗时 | 150~300 ms | **< 1 ms** | 缩短约 200 倍 |

### 为什么 filesort 消除

联合索引 `(user_id, created_at)` 按 user_id 等值定位后，created_at 在索引内天然有序。`ORDER BY created_at DESC` 直接利用索引逆序扫描（`Backward index scan`），无需额外排序。

## 连接使用率优化前后对比

| 指标 | bad（耗尽时） | good（优化后） | 改善 |
|------|--------------|---------------|------|
| max_connections | 200 | 500 | 调大 + 容量规划 |
| Threads_connected | 200（100%） | 85（17%） | 使用率降 83 个百分点 |
| Threads_running | 168 | 12 | 活跃线程降 93% |
| Threads_created 累计 | 8421 | 增长缓慢 | thread_cache_size 生效 |
| 单 SQL 耗时 | 150~300 ms | < 1 ms | 缩短 ~200 倍 |
| 单连接吞吐 | ~3 QPS | ~1000 QPS | 提升 ~300 倍 |
| "Too many connections" | 频繁 | 消失 | 根治 |

### 监控查询输出对比

```
优化前（bad）:
+----------+--------------------+-----------+
| max_conn | threads_connected  | usage_pct |
+----------+--------------------+-----------+
|      200 | 200                |     100.0 |   <- 耗尽，拒绝新连接
+----------+--------------------+-----------+

优化后（good）:
+----------+--------------------+-----------+
| max_conn | threads_connected  | usage_pct |
+----------+--------------------+-----------+
|      500 | 85                 |      17.0 |   <- 健康，余量充足
+----------+--------------------+-----------+
```

## 为什么快

1. **索引消除全表扫描**：`(user_id, created_at)` 联合索引让查询直接定位到目标行，扫描行数从 10 万降到 12
2. **索引消除 filesort**：created_at 在索引内有序，`ORDER BY` 无需额外排序
3. **连接快速释放**：单次查询从数百毫秒降到 1ms 以内，连接用完即还，吞吐量提升约 300 倍
4. **连接池配置合理**：max_connections 按容量规划设定，wait_timeout 回收泄漏连接，thread_cache_size 减少线程创建开销

## 连接池配置最佳实践

### 连接池大小计算

```
HikariCP 官方公式:
  pool_size = (CPU 核心数 * 2) + 有效磁盘数

容量规划公式:
  max_connections = 应用实例数 * 单实例 pool_size + 预留(20)

示例:
  10 个应用实例 * 20 连接 + 20 预留 = 220  ->  设 max_connections = 250~300
```

核心原则：**更多连接 ≠ 更高吞吐**。连接过多导致上下文切换开销增大，反而变慢。单实例连接池 10~20 通常足够。

### 关键参数对照

| 参数 | 推荐值 | 作用 |
|------|--------|------|
| max_connections | 容量规划值（如 500） | 全局连接上限 |
| wait_timeout | 600（10 分钟） | 非交互连接空闲超时，回收泄漏连接 |
| interactive_timeout | 600 | 交互连接空闲超时 |
| thread_cache_size | 64 | 线程缓存，减少 Threads_created 增长 |
| 连接池 maxLifetime | < wait_timeout（如 1800s） | 防止连接被服务端踢掉变死连接 |
| 连接池 connectionTimeout | 3000 ms | 获取连接超时，快速失败 |

## 监控告警阈值

| 指标 | 告警阈值 | 紧急阈值 | 查询方式 |
|------|---------|---------|---------|
| 连接使用率 | > 80% | > 95% | Threads_connected / max_connections |
| Threads_running | > 50 | > 100 | SHOW STATUS LIKE 'Threads_running' |
| 慢连接数（time>60s） | > 10 | > 50 | information_schema.PROCESSLIST |
| Threads_created 增速 | > 100/min | > 500/min | SHOW STATUS LIKE 'Threads_created' |

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| SET PERSIST | ❌ 需改 my.cnf 重启 | ✅ 运行时持久化到 mysqld-auto.cnf |
| performance_schema.threads | 需手动开启 consumers | 默认更完善 |
| SHOW PROCESSLIST | 支持 | 支持（8.0.22+ 有 PROCESSLIST 视图优化） |
| 连接诊断原理 | 一致 | 一致 |

## 避坑指南

1. **max_connections 不是越大越好**：过大导致内存占用增加（每连接约 256KB~1MB 线程栈）、上下文切换开销增大。500 是常见上限，1000+ 需评估内存。

2. **wait_timeout 必须与连接池 maxLifetime 配合**：连接池 maxLifetime 必须小于 wait_timeout，否则服务端先踢掉连接，连接池里的"死连接"会报 Communications link failure。

3. **预留 SUPER 连接**：max_connections 之外，MySQL 为 SUPER/CONNECTION_ADMIN 权限账号额外预留 1 个连接，用于故障时紧急登入排查。不要把这个名额给应用。

4. **连接池大小要小**：经验值单实例 10~20。盲目调大连接池会让数据库更慢（上下文切换），而不是更快。

5. **监控 Threads_created 增速**：如果持续快速增长，说明 thread_cache_size 太小，连接频繁创建销毁线程，调大 thread_cache_size。
