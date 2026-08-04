# 慢查询排查方法论

<CaseMeta difficulty="⭐⭐⭐" category="优化器" versions="5.7 & 8.0" :tags="['慢查询', 'slow log', 'pt-query-digest', 'performance_schema', '方法论']" />

## CPU 飙升到 90% 慢查询数万条：元凶不是改的那条 SQL
生产数据库 CPU 飙升到 90%，监控告警狂响。DBA 登录一看，慢查询数万条，根本看不出是哪条 SQL 导致的。改了半天一条 SQL，CPU 还是下不去--因为真正的"元凶"根本不是你改的那条。

```sql
-- 生产 CPU 90%，但不知道是哪条 SQL 导致的
-- 数万条慢日志，人眼看不过来，必须用工具聚合定位
```

这是所有 MySQL 优化的"第 0 步"：**先找到该优化什么，再谈怎么优化**。前 79 个案例都在讲"某条 SQL 怎么优化"，本案例讲的是"如何从海量慢查询里揪出该优化的那几条"。

::: warning 真实场景
"CPU 高却不知道优化哪条 SQL"是 DBA 最常见的困境。盲目优化单条 SQL 往往徒劳--80% 的性能问题来自 20% 的 SQL（二八定律），找到这 20% 才是关键。一套标准诊断链路：slow log 采集 -> pt-query-digest 聚合 -> performance_schema 实时统计 -> EXPLAIN ANALYZE 验证，能让你 1 小时内定位"元凶"，而不是凭直觉碰运气。
:::

## 问题分析

本案例模拟生产订单表 `t_order_diag`（50 万行），故意只建主键和 `idx_user`，缺少 `(status, created_at)` 和 `(user_id, amount)` 索引，让三类查询变慢。生产中这三条 SQL 被诊断链路揪出，合计占总耗时 85%。

### bad.sql（3 条被揪出的慢 SQL）

```sql
-- SQL 1（排名 #1，占总耗时 45%）: 深分页 + 无可用索引
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE status = 1
ORDER BY created_at DESC
LIMIT 100000, 20;

-- SQL 2（排名 #2，占总耗时 27%）: 有 idx_user 但需回表 + filesort
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE user_id = 12345
ORDER BY amount DESC;

-- SQL 3（排名 #3，占总耗时 13%）: 函数致索引失效
SELECT COUNT(*) AS order_cnt
FROM t_order_diag
WHERE DATE(created_at) = '2026-07-01';
```

### EXPLAIN 结果

**SQL 1**：全表扫描 + filesort

```
+----+-------------+--------------+------+---------------+------+---------+------+--------+-----------------------------+
| id | select_type | table        | type | possible_keys | key  | rows    |filtered| Extra                       |
+----+-------------+--------------+------+---------------+------+---------+--------+-----------------------------+
|  1 | SIMPLE      | t_order_diag | ALL  | NULL          | NULL |  498512 |  10.00 | Using where; Using filesort |
+----+-------------+--------------+------+---------------+------+---------+--------+-----------------------------+
```

**SQL 2**：走了 idx_user 但 filesort

```
+----+-------------+--------------+------+---------------+----------+---------+-------+------+----------------+
| id | select_type | table        | type | possible_keys | key      | key_len | rows  |filtered| Extra          |
+----+-------------+--------------+------+---------------+----------+---------+-------+------+----------------+
|  1 | SIMPLE      | t_order_diag | ref  | idx_user      | idx_user | 8       |  5    | 100.00 | Using filesort |
+----+-------------+--------------+------+---------------+----------+---------+-------+------+----------------+
```

**SQL 3**：函数致索引失效，全表扫描

```
+----+-------------+--------------+------+---------------+------+---------+------+--------+-------------+
| id | select_type | table        | type | possible_keys | key  | rows    |filtered| Extra       |
+----+-------------+--------------+------+---------------+------+---------+--------+-------------+
|  1 | SIMPLE      | t_order_diag | ALL  | NULL          | NULL |  498512 | 100.00 | Using where |
+----+-------------+--------------+------+---------------+------+---------+--------+-------------+
```

### 为什么慢

三条 SQL 的慢因各异，但**都是通过诊断工具才发现的**：

| SQL | 慢因 | 单次耗时 | 特点 |
|-----|------|----------|------|
| SQL 1 | 全表扫描 + filesort + 深分页三重暴击 | ~820 ms | 单次就很慢，最容易被发现 |
| SQL 2 | idx_user 只含 user_id，amount 无序需回表+filesort | ~15 ms | **单次不慢、高频成灾**，只有聚合统计才暴露 |
| SQL 3 | DATE(created_at) 对列套函数，索引失效 | ~480 ms | 写法隐蔽，常被忽视 |

::: tip 核心认知
SQL 2 是最容易被忽视的--单次 15ms 看着不慢，但每秒被调用上百次，累计总耗时排第 2。**这种"单条不慢、高频成灾"的 SQL，只有 pt-query-digest / performance_schema 的聚合统计才能发现**。人眼看慢日志会被"单次慢"的 SQL 吸引，忽略掉高频小慢查询。
:::

## 诊断方法论

这是本案例的核心：一套从"CPU 高"到"锁定元凶 SQL"的标准链路。

### 第 1 步：开启 slow log 采集

slow log 是所有诊断的原始数据来源。把超过阈值的 SQL 落盘，供后续聚合分析。

```sql
-- 查看当前配置
SHOW VARIABLES LIKE 'slow_query%';
SHOW VARIABLES LIKE 'long_query_time';

-- 运行时开启（重启失效）
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 1;                  -- 超过 1 秒记录（生产建议 0.1~1）
SET GLOBAL log_queries_not_using_indexes = 'ON'; -- 未走索引的查询也记录
SET GLOBAL min_examined_row_limit = 100;         -- 扫描行数 < 100 不记录（降噪）

-- 8.0 推荐用 SET PERSIST 持久化（写入 mysqld-auto.cnf，重启保留）
SET PERSIST slow_query_log = 'ON';
SET PERSIST long_query_time = 1;

-- 5.7 需手改 my.cnf 后重启：
--   [mysqld]
--   slow_query_log = 1
--   long_query_time = 1
--   log_queries_not_using_indexes = 1
--   slow_query_log_file = /var/log/mysql/slow.log
```

::: warning long_query_time 取值
不要设太大（如 5 秒），会漏掉高频小慢查询（如 SQL 2 那种 15ms 但每秒上百次的）；也不要设太小（如 0），日志会爆炸淹没真问题。生产经验值 0.1~1 秒，配合 `min_examined_row_limit` 降噪。
:::

### 第 2 步：pt-query-digest 聚合指纹

slow log 动辄数万条，人眼无法看。`pt-query-digest` 把常量替换成 `?`（指纹化），按 SQL 模式聚合，输出每类的总耗时、调用次数、平均耗时，快速锁定 TOP N。

```bash
# 基础用法：分析慢日志，按总耗时排序
pt-query-digest /var/log/mysql/slow.log

# 只看排名前 10 的慢查询（精简输出）
pt-query-digest --order-by Query_time:sum --limit 10 /var/log/mysql/slow.log

# 按平均耗时排序（找单次最慢的）
pt-query-digest --order-by Query_time:avg --limit 10 /var/log/mysql/slow.log
```

典型输出（节选）：

```
Rank  Query ID           Response time   Calls  R/Call   Sample
===== ================== =============== ====== ======== =============================================
1     0xABC123...        1500.0000 45.0%   1500  1.0000   SELECT t_order_diag WHERE status=? ORDER BY created_at DESC LIMIT ?,?
2     0xDEF456...         900.0000 27.0%    900  1.0000   SELECT ... FROM t_order_diag WHERE user_id=? ORDER BY amount DESC
3     0xGHI789...         440.0000 13.0%    440  1.0000   SELECT COUNT(*) FROM t_order_diag WHERE DATE(created_at)=?
----- ------------------ --------------- ------ -------- --------------------------------------------
MISC  0x...               495.0000 15.0%   5000  0.0990   <8 ITEMS>
```

结论：TOP 3 占总耗时 85%，正是本案例的 3 条问题 SQL。这就是 pt-query-digest 的价值--从海量日志里揪出"该优化什么"。

::: tip pt-query-digest 的关键能力
- **指纹化**：`WHERE status=1` 和 `WHERE status=2` 聚合成同一条 `WHERE status=?`，看清模式而非单条
- **按总耗时排序**：找累计最耗时的（高频小慢查询也能浮上来）
- **Response time 占比**：直接告诉你每类 SQL 占总耗时的百分比，TOP N 一目了然
:::

### 第 3 步：performance_schema 实时定位 TOP SQL

pt-query-digest 是"事后分析慢日志"；performance_schema 是"实时"统计，无需等日志落盘。两者交叉验证，结论更可靠。

```sql
-- TOP SQL（按总耗时排序，找累计最耗时的 SQL 模式）
SELECT
    DIGEST_TEXT                                          AS sql_fingerprint,
    COUNT_STAR                                           AS exec_count,
    ROUND(SUM_TIMER_WAIT/1000000000, 1)                  AS total_ms,
    ROUND(AVG_TIMER_WAIT/1000000000, 1)                  AS avg_ms,
    ROUND(SUM_ROWS_EXAMINED/NULLIF(COUNT_STAR,0), 0)     AS avg_rows_examined
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%t_order_diag%'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
```

典型输出：

```
sql_fingerprint                                  exec_count total_ms avg_ms avg_rows_examined
SELECT ... t_order_diag WHERE status = ? ...         1500   1500000   1000   500000    <- SQL 1
SELECT ... t_order_diag WHERE user_id = ? ...         900    900000   1000        5    <- SQL 2
SELECT COUNT(*) t_order_diag WHERE DATE(...          440    440000   1000   500000    <- SQL 3
```

排名与 pt-query-digest 一致，交叉验证了"该优化这 3 条"。

::: warning performance_schema 开启
- 8.0 默认开启，digest 采集完善，开箱即用
- 5.7 默认可能未开启，需在 my.cnf 配置 `performance_schema=ON` 并重启，还要手动启用 `events_statements_*` 的 instruments/consumers
- performance_schema 有一定性能开销（通常 <5%），生产可接受
:::

### 第 4 步：EXPLAIN ANALYZE 验证（8.0）

定位到 TOP N 后，逐条用 EXPLAIN 看执行计划。8.0 还能用 `EXPLAIN ANALYZE` 看实际执行统计，验证优化器预估是否准确。

```sql
-- 8.0 独有：EXPLAIN ANALYZE 给出实际行数和耗时
EXPLAIN ANALYZE
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE status = 1
ORDER BY created_at DESC
LIMIT 100000, 20;
-- 输出含 "rows=... loops=... (actual time=...)"，能看出实际扫描行数与回表代价
```

## 优化方案

对 3 条慢 SQL 逐条治理：建索引 + 改写 SQL。

### good.sql

```sql
-- SQL 1 优化: 建索引 idx_status_created_id + 延迟关联
ALTER TABLE t_order_diag
    ADD INDEX idx_status_created_id (status, created_at, id);

SELECT t.id, t.order_no, t.user_id, t.amount, t.status, t.created_at
FROM t_order_diag t
INNER JOIN (
    SELECT id FROM t_order_diag
    WHERE status = 1 ORDER BY created_at DESC LIMIT 100000, 20
) tmp ON t.id = tmp.id;

-- SQL 2 优化: 建复合索引 idx_user_amount
ALTER TABLE t_order_diag ADD INDEX idx_user_amount (user_id, amount);

SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE user_id = 12345
ORDER BY amount DESC;

-- SQL 3 优化: 改写为范围查询，避免对列使用函数
SELECT COUNT(*) AS order_cnt
FROM t_order_diag
WHERE created_at >= '2026-07-01 00:00:00'
  AND created_at <  '2026-07-02 00:00:00';
```

### 原理

**SQL 1（延迟关联 + 三列索引）**：
- `(status, created_at, id)` 同时满足 `WHERE status=1` 过滤 + `ORDER BY created_at DESC` 排序，索引有序无需 filesort
- 子查询 `SELECT id` 只取主键，走**覆盖索引**（索引含 id），不回表就定位目标 20 条的 id
- 外层 `JOIN tmp.id` 用主键 `eq_ref` 只回表 20 次（bad 方案回表 ~100,020 次）

**SQL 2（复合索引 idx_user_amount）**：
- `WHERE user_id=12345` 走索引第一列等值匹配
- `ORDER BY amount DESC` 用索引第二列有序性，**消除 filesort**

**SQL 3（范围查询改写）**：
- `created_at >= '...' AND created_at < '...'` 让列保持"裸"状态，消除逐行调用 `DATE()` 的开销
- 配合 `idx_created` 索引可走 `range` 扫描只读当天数据（本案例聚焦诊断链路，未单独建该索引；详见 [案例 04 函数致索引失效](../indexing/04-function-on-index)）

### 对比

| SQL | bad | good | 优化手段 |
|-----|-----|------|----------|
| SQL 1 | type=ALL, rows≈498,512, filesort | type=ref+eq_ref, 回表 20 次 | 三列索引 + 延迟关联 |
| SQL 2 | key=idx_user, filesort | key=idx_user_amount, 无 filesort | 复合索引 |
| SQL 3 | type=ALL, 逐行 DATE() | 范围查询, 消除函数 | SQL 改写 |

<ExplainCompare
  :bad="{ type: 'ALL/ref/ALL', key: 'NULL/idx_user/NULL', rows: '498,512 / 5 / 498,512', Extra: '3条慢SQL占总耗时85%，CPU 90%' }"
  :good="{ type: 'ref+eq_ref/ref/ALL', key: 'idx_status_created_id/idx_user_amount/NULL', rows: '回表20 / 5 / 498,512(无函数)', Extra: '3条优化后跌出榜单，CPU降至36%，下降60%' }"
  improvement="通过 slow log + pt-query-digest 精准定位 TOP 3，优化后整体 CPU 下降 60%"
/>

## 避坑指南

::: warning 注意事项

1. **不要只看单条慢查询**。SQL 2 那种"单次 15ms"的查询人眼最容易漏，但高频下总耗时排第 2。必须用 pt-query-digest / performance_schema 按**总耗时**聚合，才能暴露高频小慢查询。

2. **long_query_time 别设太大**。设 5 秒会漏掉 SQL 2 这类查询。生产建议 0.1~1 秒，配合 `min_examined_row_limit=100` 过掉扫描行数极少的无意义记录。

3. **slow log 会增长，记得轮转**。高并发库的 slow log 一天几个 GB，配置 logrotate 轮转，避免磁盘写满。pt-query-digest 分析前可先 `--since` / `--until` 限定时间窗口。

4. **performance_schema 与 slow log 互补**。slow log 是"事后"、performance_schema 是"实时"。线上突发问题时 performance_schema 能立刻看到 TOP SQL，不必等日志累积。

5. **EXPLAIN ANALYZE 会真实执行**。8.0 的 `EXPLAIN ANALYZE` 会真正跑一遍 SQL（带统计），对 UPDATE/DELETE 要谨慎；只读 SELECT 可放心用。普通 `EXPLAIN` 只做预估不执行。

6. **优化后要复测验证**。建索引后再跑一次 performance_schema TOP SQL，确认目标 SQL 已跌出榜单、CPU 真的降下来了。别建完索引就以为完事。
:::

::: tip 工具链速查
- **slow log**：MySQL 内置，`SHOW VARIABLES LIKE 'slow_query%'` 查看配置
- **pt-query-digest**：Percona Toolkit 组件，OS 上执行 `pt-query-digest slow.log`
- **performance_schema**：MySQL 内置，`events_statements_summary_by_digest` 表按指纹聚合
- **EXPLAIN**：看预估执行计划（5.7/8.0 都有）
- **EXPLAIN ANALYZE**：8.0 独有，看实际执行统计
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| slow log | ✅ 支持 | ✅ 支持 |
| pt-query-digest | ✅ 支持（OS 工具，与版本无关） | ✅ 支持 |
| performance_schema | ⚠️ 默认可能关闭，需手动启用 instruments/consumers | ✅ 默认开启，digest 采集完善 |
| EXPLAIN | ✅ 预估执行计划 | ✅ 预估执行计划 |
| EXPLAIN ANALYZE | ❌ 不支持 | ✅ 独有，输出实际行数和耗时 |
| 索引逆向扫描 | `Using filesort` | `Backward index scan`（无需额外排序） |
| SET PERSIST 持久化参数 | ❌ 需手改 my.cnf 重启 | ✅ 写入 mysqld-auto.cnf，重启保留 |

::: tip 8.0 的诊断优势
8.0 的 `EXPLAIN ANALYZE` 是诊断利器：当优化器预估 `rows=5` 但实际扫描 50 万行时，普通 EXPLAIN 看不出问题，EXPLAIN ANALYZE 会直接显示 `actual rows=500000`，立刻暴露预估偏差。这是 5.7 做不到的。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 80-slow-query-diagnosis

# 在 MySQL 5.7 上运行（对比，注意无 EXPLAIN ANALYZE）
./scripts/run-case.sh 80-slow-query-diagnosis --ver 5.7

# 跳过造数据重跑（50 万行造数据约需 1~2 分钟）
./scripts/run-case.sh 80-slow-query-diagnosis --no-seed
```
