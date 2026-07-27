# Dashboard 诊断参考结果 - bad.sql（问题定位阶段）

## TiDB v7.5.1（20 万行）

---

### 1. 慢查询日志（cluster_slow_query）

```sql
SELECT * FROM information_schema.cluster_slow_query ORDER BY time DESC LIMIT 5;
```

| 字段 | 示例值 | 说明 |
|------|--------|------|
| `time` | `2026-07-28 02:15:32` | 凌晨时段集中出现 |
| `query_time` | `5.23s` / `3.87s` / `1.94s` | 远超慢查询阈值（通常 300ms） |
| `digest` | `42a1c8aae6f133e9...` | 多个慢查询共享同一 Digest |
| `query` | `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` | 全表扫描类查询 |
| `instance` | `tidb-server-1:4000` | 集中在单个 TiDB 节点 |

**诊断结论**：凌晨时段出现一批慢查询，Digest 相同说明是同一类 SQL 模板被高频执行，query_time 达到秒级。

---

### 2. 活跃进程列表（cluster_processlist）

```sql
SELECT * FROM information_schema.cluster_processlist WHERE command != 'Sleep' AND time > 1;
```

| ID | USER | INSTANCE | COMMAND | TIME(s) | STATE | INFO |
|----|------|----------|---------|---------|-------|------|
| 1023 | root | tidb-1:4000 | Query | 45 | Sending data | `SELECT * FROM t_diag WHERE city = 'Beijing' AND score > 80` |
| 1024 | root | tidb-1:4000 | Query | 43 | Sending data | `SELECT * FROM t_diag WHERE city = 'Shanghai' AND score > 90` |
| 1025 | root | tidb-1:4000 | Query | 41 | Sending data | `SELECT * FROM t_diag WHERE city = 'Beijing' AND score > 70` |
| 1026 | root | tidb-2:4000 | Query | 38 | Sending data | `SELECT * FROM t_diag WHERE city = 'Shenzhen' ORDER BY score LIMIT 100` |
| 1028 | root | tidb-1:4000 | Query | 2 | executing | `SELECT DIGEST_TEXT, EXEC_COUNT FROM cluster_statements_summary` |

**诊断结论**：多个查询长时间处于 `Sending data` 状态，说明 TiKV 正在大量回表读取数据。`city` 列虽有索引 `idx_city`，但 `SELECT *` 导致必须回表取 `name, age, user_id` 等非索引列。

---

### 3. TopSQL 数据源（cluster_statements_summary — 按平均延迟排序）

```sql
SELECT DIGEST_TEXT, SUM_EXEC_COUNT, AVG_LATENCY, MAX_LATENCY
FROM information_schema.cluster_statements_summary
ORDER BY AVG_LATENCY DESC LIMIT 5;
```

| DIGEST_TEXT | EXEC_COUNT | AVG_LATENCY(ms) | MAX_LATENCY(ms) |
|-------------|------------|-----------------|-----------------|
| `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` | 15,230 | 2,340.5 | 8,210.0 |
| `SELECT * FROM t_diag WHERE user_id = ? ORDER BY created_at DESC LIMIT ?` | 8,450 | 450.2 | 1,200.0 |
| `SELECT COUNT(*) FROM t_diag WHERE city = ? AND age BETWEEN ? AND ?` | 3,200 | 320.8 | 980.0 |
| `INSERT INTO t_diag (user_id, name, age, city, score) VALUES (?, ?, ?, ?, ?)` | 120,000 | 2.1 | 35.0 |
| `UPDATE t_diag SET score = ? WHERE user_id = ? AND city = ?` | 45,000 | 1.8 | 28.0 |

**诊断结论**：`AVG_LATENCY = 2340ms` 的 SELECT 是主要瓶颈——平均每次执行耗时 2.3 秒，但执行次数高达 15,230 次。

---

### 4. CPU 消耗排名（cluster_statements_summary — 按 CPU 时间排序）

```sql
SELECT DIGEST_TEXT, AVG_CPU_TIME_MS, SUM_CPU_TIME_MS
FROM information_schema.cluster_statements_summary
ORDER BY SUM_CPU_TIME_MS DESC LIMIT 5;
```

| DIGEST_TEXT | AVG_CPU_TIME_MS | SUM_CPU_TIME_MS |
|-------------|-----------------|-----------------|
| `SELECT * FROM t_diag WHERE city = ? AND score > ? ORDER BY created_at` | 450.3 | 6,858,069 |
| `SELECT * FROM t_diag WHERE user_id = ? ORDER BY created_at DESC LIMIT ?` | 85.6 | 723,320 |
| `SELECT COUNT(*) FROM t_diag WHERE city = ? AND age BETWEEN ? AND ?` | 62.1 | 198,720 |
| `INSERT INTO t_diag ( ... ) VALUES ( ... )` | 0.3 | 36,000 |
| `UPDATE t_diag SET score = ? WHERE user_id = ? AND city = ?` | 0.2 | 9,000 |

**诊断结论**：`SUM_CPU_TIME_MS = 6,858,069ms`（约 1.9 小时 CPU 时间）被第一条 SQL 独占。Dashboard TopSQL 面板会以柱状图可视化这个数据，该 SQL 占据了集群 CPU 总消耗的 80%+。

---

### 5. Dashboard 各模块核心诊断指标汇总

| Dashboard 模块 | 数据来源 | 核心诊断指标 | 本案例异常值 | 根因指向 |
|---------------|---------|-------------|-------------|---------|
| **Slow Query** | `information_schema.cluster_slow_query` | 慢查询数量、query_time、Digest | 凌晨集中出现 5 条，query_time 高达 8.2s | 全表扫描类 SQL |
| **TopSQL (CPU)** | `information_schema.cluster_statements_summary` | SUM_CPU_TIME_MS、EXEC_COUNT | CPU 总耗时 6,858,069ms，占集群 80%+ | `SELECT * FROM t_diag` |
| **TopSQL (延迟)** | `information_schema.cluster_statements_summary` | AVG_LATENCY、MAX_LATENCY | 平均延迟 2.3s，最高 8.2s | 缺失覆盖索引 |
| **Statement Analysis** | `information_schema.cluster_statements_summary` | EXEC_COUNT、PLAN_DIGEST | 执行 15,230 次且每次 2.3s | SQL 模板未被优化 |
| **Key Visualizer** | PD API（Region 读写流量） | 读写字节数/Region、热点分布 | `idx_city` Region 读取流量激增 | 热点集中在 `Beijing` 城市索引 |
| **Process List** | `information_schema.cluster_processlist` | 活跃连接数、STATE | 多个 `Sending data` 状态，持续 40s+ | 回表开销大 |
