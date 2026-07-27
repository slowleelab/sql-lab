# EXPLAIN 参考结果 - bad.sql（连接耗尽，慢 SQL 全表扫描）

## MySQL 8.0（实测 8.0.46，t_conn_test 10 万行）

### 慢 SQL 的 EXPLAIN

```sql
SELECT id, user_id, data_value, created_at
FROM t_conn_test
WHERE user_id = 7321
ORDER BY created_at DESC
LIMIT 20;
```

```
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
| id | select_type | table       | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra                       |
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
|  1 | SIMPLE      | t_conn_test | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 100120 |    10.00 | Using where; Using filesort |
+----+-------------+-------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | 全表扫描，无可用索引 |
| possible_keys | `NULL` | user_id 无索引，优化器无路可选 |
| key | `NULL` | 未使用任何索引 |
| rows | `100120` | 扫描全部 10 万行（几乎全表） |
| filtered | `10.00` | 过滤后仅 10% 有效，大量无效扫描 |
| Extra | `Using where; Using filesort` | 手动过滤 + filesort 排序（created_at 无索引） |
| 单次耗时 | ~150~300 ms | 全表扫描 + filesort |

## 故障时 SHOW PROCESSLIST 模拟输出

连接已耗尽（max_connections=200），大量连接被同一条慢 SQL 占用：

```
+-----+------+-----------------+------+---------+------+------------+----------------------------------------------------------+
| Id  | User | Host            | db   | Command | Time | State      | Info                                                     |
+-----+------+-----------------+------+---------+------+------------+----------------------------------------------------------+
|   1 | app  | 10.0.0.11:39201 | prod | Query   |  312 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
|   2 | app  | 10.0.0.12:41088 | prod | Query   |  298 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
|   3 | app  | 10.0.0.11:39455 | prod | Query   |  287 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
|   4 | app  | 10.0.0.13:40099 | prod | Query   |  276 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
|   5 | app  | 10.0.0.14:41120 | prod | Query   |  265 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
| ... | ...  | ...             | ...  | ...     |  ... | ...        | ...                                                      |
| 198 | app  | 10.0.0.15:38812 | prod | Query   |  120 | Sending data| SELECT id,user_id,data_value,created_at FROM t_conn_test |
| 199 | app  | 10.0.0.16:40021 | prod | Sleep   |   15 |            | NULL                                                     |
| 200 | app  | 10.0.0.16:40130 | prod | Sleep   |   42 |            | NULL                                                     |
| 201 | dba  | 127.0.0.1:50123 | NULL | Query   |    0 | starting   | SHOW PROCESSLIST                                          |
+-----+------+-----------------+------+---------+------+------------+----------------------------------------------------------+
```

关键信号：
- **Time 列 100~312 秒**：连接被慢 SQL 占用数分钟未释放
- **State 全是 "Sending data"**：所有活跃连接都在执行这条慢查询
- **Info 高度重复**：几乎全是 `t_conn_test WHERE user_id=...`，锁定罪魁 SQL
- **199/200 是 Sleep**：空闲连接也被连接池持有，加剧耗尽

## SHOW STATUS LIKE 'Threads%' 模拟输出

```
+-------------------+-------+
| Variable_name     | Value |
+-------------------+-------+
| Threads_cached    | 0     |   <- 线程缓存空，频繁建线程
| Threads_connected | 200   |   <- 已达 max_connections 上限
| Threads_created   | 8421  |   <- 累计创建线程数异常高
| Threads_running   | 168   |   <- 168 个线程同时在跑慢 SQL
+-------------------+-------+
```

连接使用率：

```
+----------+--------------------+-----------+
| max_conn | threads_connected  | usage_pct |
+----------+--------------------+-----------+
|      200 | 200                |     100.0 |   <- 100% 耗尽，拒绝新连接
+----------+--------------------+-----------+
```

## 连接耗尽根因分析

### 雪崩链条

```
1. 某接口上线，新 SQL 缺索引 -> 单次 150~300ms 全表扫描
2. 业务 QPS 1000，每秒 1000 个连接请求执行此慢 SQL
3. 单连接被占用 150~300ms，吞吐 = 1000ms/300ms ≈ 3 QPS/连接
4. 支撑 1000 QPS 需 1000/3 ≈ 334 连接，但 max_connections=200
5. 连接迅速被打满 -> 新请求拿不到连接 -> "Too many connections"
6. 应用层连接池获取超时 -> 请求堆积 -> 线程池打满 -> 服务雪崩
```

### 三类常见根因对比

| 根因 | 特征 | PROCESSLIST 表现 | 本案例 |
|------|------|------------------|--------|
| 慢 SQL 占连接 | Time 高、State=Sending data、Info 重复 | 集中在某几条 SQL | ✅ 主因 |
| 连接泄漏 | Time 高、State=Sleep、Info=NULL | 大量空闲连接不归还 | 部分（199/200） |
| 突发流量 | 短时间 connections 暴增 | QPS 突增，连接数同步涨 | 触发因素 |

本案例是**慢 SQL 占连接**为主因，叠加应用连接池泄漏（Sleep 连接）共同导致耗尽。

## 实际耗时

单次慢 SQL 约 **150~300 ms**（全表扫描 10 万行 + filesort），高并发下 168 个连接同时执行，连接池在数秒内被占满。

## MySQL 5.7 差异

- 5.7 的 `SHOW PROCESSLIST` 同样可用，但 `information_schema.PROCESSLIST` 仅 5.7.9+ 支持过滤
- 5.7 `performance_schema.threads` 默认可能未开启，需 `UPDATE performance_schema.setup_consumers SET ENABLED='YES' WHERE NAME='events_statements_current'`
- EXPLAIN 输出格式基本一致，5.7 无 `partitions` 列默认显示差异
