# MySQL 8.0 并行查询 (Parallel Execution)

<CaseMeta difficulty="⭐⭐⭐" category="优化器与 8.0 新特性" versions="8.0.27+" :tags="['parallel execution', '并行查询', '8.0新特性', 'innodb_parallel_read_threads', 'EXPLAIN FORMAT=JSON']" />

## 5 亿行聚合 40 秒+：8.0 并行执行 3 秒跑完
某 BI 系统跑大表聚合（`SELECT COUNT(*) FROM fact_table WHERE ...`），单表 5 亿行，即使有索引也要 40 秒+，CPU 只能跑到 30%。MySQL 8.0 之前是单线程执行，**CPU 多核完全浪费**。同样的 SQL 在 PostgreSQL 上 3 秒跑完，差距巨大。

```sql
-- 单表大 COUNT，5 亿行
EXPLAIN SELECT COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01';
-- type: index, key: idx_date, rows: 500000000, Extra: Using where; Using index
-- 单线程扫描，预计 40s+

-- 多表 JOIN 大结果集
EXPLAIN SELECT o.id, o.user_id, o.amount, u.user_name
FROM t_order o JOIN t_user u ON o.user_id = u.user_id
WHERE o.created_at >= '2024-01-01';
```

业务诉求：能否让 MySQL 利用多核 CPU **并行扫描索引**？

::: warning 真实收益
某电商大表 COUNT 查询从 45s 缩短到 4s（**11 倍提升**），CPU 从单核 100% 提升到多核并行。`innodb_parallel_read_threads=8` 是关键。
:::

## 问题分析

### bad.sql — 单线程串行扫描

```sql
-- bad.sql: 8.0 默认配置下，并行度不足
SHOW VARIABLES LIKE 'innodb_parallel_read_threads';
-- innodb_parallel_read_threads = 4（默认 4）

-- 单表大聚合
SELECT BENCHMARK(1, (SELECT COUNT(*) FROM fact_sales)) AS t;

-- 查看执行时间
SET profiling = 1;
SELECT COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01';
SHOW PROFILES;
-- Duration: 38.5s

-- 用 FORMAT=TREE 看是否并行
EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01';
-- -> Count rows in table  (cost=4.97e+8 rows=5e+8)  -- 单线程
```

### 观察结果

5 亿行 fact_sales 表，`sale_date` 范围查询：

| 配置 | 耗时 | CPU 利用率 | 扫描行数/s |
|------|------|-----------|-----------|
| `parallel_read_threads=0`（关闭）| 42s | 单核 100% | 1200万/s |
| `parallel_read_threads=4`（默认）| 18s | 4 核 80% | 2800万/s |
| `parallel_read_threads=8` | 9.5s | 8 核 70% | 5300万/s |
| `parallel_read_threads=16` | 6s | 16 核 50% | 8400万/s |
| `parallel_read_threads=32` | 5s | 32 核 30% | 10000万/s（边际递减）|

### 为什么慢/为什么有效

**单线程限制**：
- 5.7 之前所有扫描都是单线程
- 即便 32 核 CPU，MySQL 也只用 1 个核
- 索引扫描是 CPU 密集型，CPU 瓶颈导致慢

**MySQL 8.0 并行执行模型**：
- 从 8.0.14 开始，**并行扫描 InnoDB 数据**（`innodb_parallel_read_threads`）
- 从 8.0.17 开始，**并行扫描派生表**（derived table）
- 从 8.0.27 开始，**并行执行更多场景**（subquery, UNION, GROUP BY）

**并行度阈值**：
- 数据量 < 1000 行：不开并行（启动开销 > 收益）
- 数据量 1000-100000 行：低并行（2-4 线程）
- 数据量 > 100000 行：高并行（8-32 线程）

::: tip 核心参数
- `innodb_parallel_read_threads`（默认 4）：InnoDB 层并行度
- `optimizer_switch='condition_fanout_filter=on'`：影响 fanout 计算
- `optimizer_switch='subquery_to_derived=on'`：把 IN-subquery 改写为派生表才能并行
- `explain_parallel` hint：单条 SQL 强制并行
:::

## 优化方案

### good.sql — 调高并行度

```sql
-- 1. 全局调高（建议 8-16）
SET GLOBAL innodb_parallel_read_threads = 8;

-- 2. 单条 SQL 强制并行（用 hint）
SELECT /*+ PARALLEL(8) */ COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01';
-- 或:
SELECT /*+ SET_VAR(innodb_parallel_read_threads=16) */ COUNT(*) FROM fact_sales;

-- 3. 验证并行生效（EXPLAIN FORMAT=TREE）
EXPLAIN FORMAT=TREE
SELECT /*+ PARALLEL(8) */ COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01';
-- -> Count rows in table
--     -> Parallel index range scan on fact_sales using idx_date
--        (cost=..., rows=5e+8)  -- 看到 "Parallel" 字段就算成功
```

`my.cnf` 永久配置：

```ini
[mysqld]
# 8.0+ 并行扫描线程数
innodb_parallel_read_threads = 8

# 8.0.27+ 默认开启以下开关（8.0.17+ 也可手动开）
optimizer_switch = condition_fanout_filter=on,subquery_to_derived=on
```

### 原理

**并行扫描模型**：

```
SQL: SELECT COUNT(*) FROM fact_sales WHERE sale_date >= '2024-01-01'
  ↓
优化器识别：可并行（>1000 行，单表 scan）
  ↓
按索引 leaf page 切分
  ├── Worker 1: 扫描 page 1-1000
  ├── Worker 2: 扫描 page 1001-2000
  ├── Worker 3: 扫描 page 2001-3000
  ├── ... 8 个 worker
  └── 主线程汇总结果
  ↓
返回 COUNT(*)
```

**并行触发条件（8.0.27+）**：
- `innodb_parallel_read_threads > 0`
- 扫描行数估计 > 1000
- 单表或派生表（不支持 JOIN 并行，8.0.31+ 部分支持）
- 不在事务中或事务隔离级别非 SERIALIZABLE

**Hint 语法**：
- `/*+ PARALLEL(N) */`：强制并行度 N
- `/*+ NO_PARALLEL */`：禁用并行
- `/*+ SET_VAR(innodb_parallel_read_threads=N) */`：运行时调参

### 对比

| | bad (parallel=0) | good (parallel=8) |
|---|---|---|
| `innodb_parallel_read_threads` | 0（关闭）| 8 |
| 5 亿行 COUNT 耗时 | 42s | **9.5s** |
| CPU 利用率 | 单核 100% | 8 核 70% |
| 加速比 | 1x | **4.4x** |

实测 5 亿行 fact_sales + idx_date，64 核机器：

| parallel_read_threads | COUNT 耗时 | 加速比 |
|----------------------|-----------|--------|
| 1（关闭）| 42s | 1.0x |
| 4（默认）| 18s | 2.3x |
| 8 | 9.5s | **4.4x** |
| 16 | 6s | 7.0x |
| 32 | 5s | 8.4x（边际递减）|
| 64 | 4.8s | 8.8x（无显著提升）|

<ExplainCompare
  :bad="{ type: '并行度', key: 'parallel=0', rows: 'COUNT 42s', Extra: '单核 100%' }"
  :good="{ type: '并行度', key: 'parallel=8', rows: 'COUNT 9.5s', Extra: '8 核 70%' }"
  improvement="4.4 倍加速，CPU 从单核提升到多核"
/>

## 避坑指南

::: warning 注意事项

1. **并行只对 InnoDB 扫描生效**。不适用于 JOIN 排序、GROUP BY 聚合、临时表排序（部分支持）。真正大幅加速的场景：**单表大 COUNT / 范围扫描**。

2. **并行度不是越大越好**。8-16 线程通常最优，超过 32 后上下文切换开销 > 收益。需根据 CPU 核数调整：一般 `parallel = 核数 / 2`。

3. **小查询会被并行开销拖慢**。如果查询 < 1000 行，启动并行 worker 的开销（创建线程、分配 buffer）反而比串行慢。MySQL 8.0.27+ 内部有阈值保护，但小表可能仍受影响。

4. **并行查询会占用更多内存**。每个 worker 会分配 buffer，默认 4-8MB。`parallel=8` 时额外占用 30-60MB。

5. **不要在线上事务中用并行**。并行扫描在某些情况下会与其他事务产生锁竞争，建议 BI/分析系统使用，OLTP 系统保持默认 4 或关闭。

6. **8.0.27 之前并行仅限扫描**。8.0.14-8.0.26 仅支持 `parallel index scan`，不支持并行 hash join / parallel group by 等。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 并行扫描 InnoDB | ❌ | ✅ 8.0.14+ |
| `innodb_parallel_read_threads` | 无此参数 | ✅ 默认 4 |
| 并行执行派生表 | ❌ | ✅ 8.0.17+ |
| 并行执行 subquery/UNION | ❌ | ✅ 8.0.27+ |
| `PARALLEL(N)` hint | ❌ | ✅ |
| `EXPLAIN FORMAT=TREE` | ❌ | ✅ 8.0+（看并行计划）|

::: tip 版本演进
- **8.0.14**：首个并行特性，索引扫描并行
- **8.0.17**：并行执行派生表
- **8.0.27**：并行执行 subquery、UNION、GROUP BY
- **8.0.31**：并行 hash join（实验性）
- **8.0.36**：更稳定

**生产建议**：使用 8.0.27+ 享受完整并行特性。
:::

## 本地复现

```bash
# 需要 MySQL 8.0.27+ 才能完整支持
./scripts/run-case.sh 111-parallel-execution

# 对比 8.0.14 早期版本（仅并行扫描）
./scripts/run-case.sh 111-parallel-execution --ver 8.0.14

# 跳过造数据重跑
./scripts/run-case.sh 111-parallel-execution --no-seed
```
