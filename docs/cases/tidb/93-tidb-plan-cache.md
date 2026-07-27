# TiDB Plan Cache 执行计划缓存

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['Plan Cache', 'Prepared Statement', 'prepare', '缓存']" />

## 场景痛点

你在负责一个高并发 OLTP 业务，某天运维告警显示 TiDB 集群的 CPU 使用率从 40% 飙升至 80%。查看 Grafana 监控面板，发现 TiDB Server 层的 CPU 消耗占了集群总 CPU 的 60% 以上。你检查了慢查询日志，并没有发现慢 SQL；进程列表中也没有锁等待或长事务。

进一步分析发现：**你的应用代码中没有使用 Prepared Statement**。所有查询都是以拼接字符串的方式发送到 TiDB——即使查询模式完全相同（例如按用户 ID 查信息），因为 user_id 的常量值不同，每条 SQL 都被视为全新的语句：

```sql
-- 应用代码中构造的三条 SQL：
SELECT id, name, score FROM t_user WHERE user_id = 100;
SELECT id, name, score FROM t_user WHERE user_id = 200;
SELECT id, name, score FROM t_user WHERE user_id = 300;
-- TiDB 对此的处理：三次独立解析 + 三次独立优化 + 三次独立生成执行计划
```

在 5000 QPS 的并发负载下，这意味着优化器每秒要处理几千次完全相同的优化工作，大量 CPU 时间被浪费在重复的解析和优化上。

::: warning 真实场景

TiDB 优化器对单条 SQL 的优化耗时通常在 0.3-1ms，对于单次查询来说毫不起眼。但在高并发 OLTP 场景（1 万+ QPS），优化器的累计 CPU 开销可能占据 TiDB Server 30-50% 的 CPU 时间——而这些开销全是"重复劳动"。Plan Cache 就是为消除这种重复而设计的。

:::

## 问题分析

### TiDB Plan Cache 的工作原理

TiDB 的 Plan Cache 是一种 **基于 Prepared Statement 的执行计划缓存**。它的核心机制：

```
应用端                          TiDB Server
  │                                │
  │  PREPARE stmt FROM '...'       │
  │──────────────────────────────►│ 注册 SQL 模板（解析但不优化）
  │                                │
  │  EXECUTE stmt USING @p1       │
  │──────────────────────────────►│ 第1次：Plan Cache MISS
  │                                │   ├─ 绑定参数值
  │                                │   ├─ 逻辑优化 + 物理优化
  │                                │   ├─ 生成执行计划
  │                                │   ├─ 以 SQL 模板哈希为 key 缓存计划
  │                                │   └─ 执行
  │                                │
  │  EXECUTE stmt USING @p2       │
  │──────────────────────────────►│ 第2次：Plan Cache HIT
  │                                │   ├─ 根据 SQL 模板哈希查找缓存
  │                                │   ├─ 验证计划有效性
  │                                │   ├─ 绑定新参数值
  │                                │   └─ 直接执行（跳过优化）
```

缓存 key 是 SQL 模板的 `SQL_DIGEST`（参数化后的 SQL 指纹），而非完整 SQL 文本。

### bad.sql：不使用 Prepared Statement

```sql
-- 1. 普通 SQL（每次优化器都要重新解析和优化）
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 100;
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 200;
EXPLAIN SELECT id, name, score FROM t_plan_cache WHERE user_id = 300;

-- 2. 检查 Plan Cache 状态 —— 全为 0
SHOW GLOBAL STATUS LIKE 'Plan_cache%';
```

Plan Cache 状态：

```
Plan_cache_hit           | 0      ← 从未命中
Plan_cache_miss          | 0      ← 也未产生 miss
Plan_cache_memory_usage  | 0      ← 内存占用为 0
```

关键发现：**普通 SQL 完全绕过了 Plan Cache 机制**。`Plan_cache_miss` 为 0 说明这些 SQL 根本不经过 Plan Cache 路径——TiDB 不会对非 Prepared Statement 做任何缓存尝试。

### 三条相同的执行计划，三次完整的优化

```
EXPLAIN SELECT ... WHERE user_id = 100:
+-----------------------+--------+-----------+-------------------------+
| IndexLookUp_7         | 10.00  | root      |                         |
| ├─IndexRangeScan(Build)| 10.00  | cop[tikv] | idx_user, range:[100,100]|
| └─TableRowIDScan(Probe)| 10.00  | cop[tikv] | t_plan_cache            |
+-----------------------+--------+-----------+-------------------------+

EXPLAIN SELECT ... WHERE user_id = 200:
+-----------------------+--------+-----------+-------------------------+
| IndexLookUp_7         | 10.00  | root      |                         |
| ├─IndexRangeScan(Build)| 10.00  | cop[tikv] | idx_user, range:[200,200]|
| └─TableRowIDScan(Probe)| 10.00  | cop[tikv] | t_plan_cache            |
+-----------------------+--------+-----------+-------------------------+

EXPLAIN SELECT ... WHERE user_id = 300:
+-----------------------+--------+-----------+-------------------------+
| IndexLookUp_7         | 10.00  | root      |                         |
| ├─IndexRangeScan(Build)| 10.00  | cop[tikv] | idx_user, range:[300,300]|
| └─TableRowIDScan(Probe)| 10.00  | cop[tikv] | t_plan_cache            |
+-----------------------+--------+-----------+-------------------------+
```

三条 SQL 的执行计划树完全一致——`IndexLookUp` (Build: `IndexRangeScan` + Probe: `TableRowIDScan`)，唯一的区别是 `range` 中的常量值。但 TiDB 对每条都执行了完整的优化流程：SQL 解析 → AST 构建 → 逻辑优化（列裁剪、谓词下推等）→ 物理优化（算子选择、成本估算）→ 生成最终执行计划。

::: tip 核心认知

Plan Cache 并非 MySQL Query Cache 的替代品。Plan Cache 缓存的是**执行计划**（优化器的输出），而不是查询结果。它的目标是消除"重复优化"，而非"重复执行"。即使 Plan Cache 命中，每次 `EXECUTE` 仍然会去 TiKV 读取最新的数据——这与 MySQL 5.7 Query Cache 返回过时结果的行为完全不同。

:::

## 优化方案

### good.sql：使用 Prepared Statement

```sql
-- 1. 确保 Plan Cache 已启用
SET GLOBAL tidb_enable_prepared_plan_cache = ON;

-- 2. 设置缓存容量
SET GLOBAL tidb_prepared_plan_cache_size = 100;

-- 3. 使用 Prepared Statement
PREPARE stmt FROM 'SELECT id, name, score FROM t_plan_cache WHERE user_id = ?';
SET @uid = 100;  EXECUTE stmt USING @uid;  -- 第1次：MISS → 优化并缓存
SET @uid = 200;  EXECUTE stmt USING @uid;  -- 第2次：HIT → 直接复用
SET @uid = 300;  EXECUTE stmt USING @uid;  -- 第3次：HIT → 直接复用
DEALLOCATE PREPARE stmt;

-- 4. 查看命中统计
SHOW GLOBAL STATUS LIKE 'Plan_cache%';
```

Plan Cache 命中统计：

```
Plan_cache_hit           | 2      ← 第2次和第3次 EXECUTE 命中
Plan_cache_hit_select    | 2      ← SELECT 类型命中数
Plan_cache_miss          | 1      ← 第1次 EXECUTE 未命中
Plan_cache_memory_usage  | 512    ← 缓存占用 512 字节
```

### EXPLAIN FORMAT=plan_cache

```sql
EXPLAIN FORMAT=plan_cache SELECT id, name, score FROM t_plan_cache WHERE user_id = ?;
```

```
+-----------------------+--------+-----------+------------------------------+
| IndexLookUp_7         | 10.00  | root      |                              |
| ├─IndexRangeScan(Build)| 10.00  | cop[tikv] | idx_user, range:[?,?]         |
| └─TableRowIDScan(Probe)| 10.00  | cop[tikv] | t_plan_cache                 |
+-----------------------+--------+-----------+------------------------------+
```

`range` 显示为 `[?,?]` 而非具体值——这是缓存计划的特征：参数被占位符取代。

### 应用层适配

| 语言/框架 | 使用 Prepared Statement 的方式 |
|----------|------------------------------|
| Go (database/sql) | `db.Query("SELECT ... WHERE user_id = ?", uid)` — 默认使用 Prepared Statement |
| Java (JDBC) | `PreparedStatement ps = conn.prepareStatement("SELECT ... WHERE user_id = ?")` |
| Python (mysql-connector) | `cursor.execute("SELECT ... WHERE user_id = %s", (uid,))` — 参数化查询 |
| Node.js (mysql2) | `connection.execute("SELECT ... WHERE user_id = ?", [uid])` — `.execute()` 而非 `.query()` |
| Hibernate/MyBatis | 默认对 JPQL/SQL 模板使用参数化，自动受益 |
| GORM (Go) | `db.Where("user_id = ?", uid).Find(&results)` — 默认参数化 |

大多数现代 ORM 和数据库驱动默认使用参数化查询，自动享受 Plan Cache。如果你发现 Plan Cache 命中率为 0，检查应用是否使用了原始字符串拼接。

## 深入原理

### Plan Cache vs MySQL Query Cache 对比

许多从 MySQL 迁移过来的用户会将 Plan Cache 与 MySQL Query Cache 混淆。它们是两种完全不同的机制：

| 维度 | TiDB Plan Cache | MySQL Query Cache (5.7, 已废弃) |
|------|----------------|-------------------------------|
| 缓存内容 | **执行计划**（如何查） | **查询结果**（查到了什么） |
| 缓存粒度 | SQL 模板级别（参数化后） | SQL 文本级别（逐字节匹配） |
| 命中条件 | 同一 Prepared Statement 的重复 EXECUTE | 完全相同的 SQL 文本 + 相同的数据库/字符集 |
| 数据新鲜度 | 每次执行都从 TiKV 读取最新数据 | 返回缓存结果，可能过时 |
| 失效机制 | 统计信息变更、schema 变更时清除 | 任何涉及表的写操作导致整表缓存失效 |
| 适用场景 | 高并发 OLTP（相同模式的重复查询） | 读多写少（MySQL 5.7 时代） |
| 高并发表现 | 好（读自己的数据，无锁竞争） | 差（全局锁导致性能瓶颈） |
| 当前状态 | TiDB 主力推荐 | MySQL 8.0 已移除 |

**关键区别**：Plan Cache 不缓存数据，只缓存"怎么查"。即使 Plan Cache 命中，TiDB 仍然会执行实际的 KV 读取操作，数据是最新的。而 MySQL Query Cache 返回的是"旧结果"，任何对该表的写入都会导致缓存大范围失效。

### Plan Cache 的内部机制

**1. 缓存 Key：SQL 模板的 Digest**

TiDB 对 Prepared Statement 的 SQL 文本做参数化处理——将所有常量值替换为 `?` 占位符，然后计算 SHA-256 哈希作为 `SQL_DIGEST`：

```
SQL 模板: SELECT id, name, score FROM t_plan_cache WHERE user_id = ?
          ↓ SHA-256
SQL_DIGEST: 42a1c8aae6f133e9...
```

这个 `SQL_DIGEST` 就是 Plan Cache 的查找 key。

**2. 计划有效性验证**

即使 `SQL_DIGEST` 匹配，TiDB 也不会盲目复用计划。每次 `EXECUTE` 前它会验证：

- **Schema 版本**：表结构是否变更（添加/删除列、索引等）
- **统计信息版本**：统计信息是否更新（影响成本估算）
- **参数类型兼容性**：参数类型是否与缓存的计划匹配

如果任何检查失败，TiDB 会淘汰旧缓存并重新优化。

**3. 缓存淘汰策略：LRU**

`tidb_prepared_plan_cache_size` 控制最大缓存条目数（默认 100）。当缓存满时，TiDB 使用 LRU（最近最少使用）策略淘汰最不活跃的计划。这是一个**按条目数**的限制，而非按内存大小。

**4. 缓存的存储位置**

Plan Cache 是**会话级别**的缓存，存储在每个 TiDB Server 连接的内存中。不同连接的 Plan Cache 是独立的——这意味着：

- 连接 A 第一次 EXECUTE 会触发 miss（即使连接 B 已缓存了相同计划）
- 连接池中的长连接天然受益：一旦缓存在连接中建立，后续所有请求都命中
- 短连接（每次请求新建连接）无法受益于 Plan Cache

### Plan Cache 的参数化限制

以下 Prepared Statement 中的模式**不能**被缓存：

```
✗ ORDER BY/GROUP BY 中有变量表达式
  SELECT * FROM t WHERE city = ? ORDER BY ?     -- 排序列由变量决定

✗ LIMIT 使用了变量
  SELECT * FROM t WHERE city = ? LIMIT ?, ?     -- LIMIT/OFFSET 都是变量

✗ 包含子查询
  SELECT * FROM t WHERE id IN (SELECT id FROM t2 WHERE col = ?)

✗ SELECT ... FOR UPDATE
  SELECT * FROM t WHERE id = ? FOR UPDATE       -- 锁定子句无法缓存

✗ IGNORE_PLAN_CACHE hint 显式禁用
  SELECT /*+ IGNORE_PLAN_CACHE() */ * FROM t WHERE id = ?
```

对于这些无法缓存的情况，`Plan_cache_unmatched` 计数器会增加：

```sql
SHOW GLOBAL STATUS LIKE 'Plan_cache_unmatched';
```

### 监控与诊断

```sql
-- Plan Cache 相关变量
SHOW VARIABLES LIKE 'tidb_prepared_plan_cache%';

-- Plan Cache 命中率
SELECT
  @@tidb_enable_prepared_plan_cache AS plan_cache_enabled,
  (SELECT VARIABLE_VALUE FROM information_schema.cluster_status
   WHERE VARIABLE_NAME = 'Plan_cache_hit') AS hits,
  (SELECT VARIABLE_VALUE FROM information_schema.cluster_status
   WHERE VARIABLE_NAME = 'Plan_cache_miss') AS misses;

-- 查看当前缓存的所有计划
SELECT * FROM information_schema.cluster_plan_cache;
```

也可以在 Grafana 的 **TiDB → Query Summary → Plan Cache OPS** 面板中观察命中率趋势。

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 93-tidb-plan-cache --ver tidb
```

执行后观察：

- `EXPLAIN SELECT ...` 输出的执行计划结构
- `SHOW GLOBAL STATUS LIKE 'Plan_cache%'` 在 bad.sql（全为 0）和 good.sql（hit=2, miss=1）中的差异
- `information_schema.cluster_plan_cache` 中缓存的计划条目
- `EXPLAIN FORMAT=plan_cache` 显示的参数化计划（range 中的 `[?,?]`）

::: tip 如何判断是否需要启用/优化 Plan Cache

1. **看 QPS 和查询模式**：如果 QPS > 1000 且大量查询来自相同的 SQL 模板，Plan Cache 收益显著
2. **看 Grafana**：TiDB → Query Summary 中的 Plan Cache Hit Rate，低于 80% 需要排查
3. **看应用代码**：检查是否使用了 Prepared Statement（ORM 通常默认启用）
4. **看 Plan_cache_unmatched**：如果该值持续增长，说明有大量 Prepared Statement 因参数化限制而无法使用缓存，需要分析具体 SQL 模式
5. **合理设置缓存大小**：`tidb_prepared_plan_cache_size` 建议设置为业务中不同 Prepared Statement 模板数量的 1.5-2 倍（默认 100 对大多数业务足够）

:::

## 常见问题

**Q: Plan Cache 会返回过时数据吗？**

A: 不会。Plan Cache 只缓存"执行计划"（怎么查），不缓存"查询结果"（查到了什么）。每次 `EXECUTE` 仍然会从 TiKV 读取最新数据。这是与 MySQL 5.7 Query Cache 的本质区别。

**Q: 为什么我的 Plan Cache 命中率很低？**

A: 常见原因有三个：(1) 应用没有使用 Prepared Statement（ORM 配置问题或原始字符串拼接）；(2) 连接池中短连接过多（Plan Cache 是连接级别的，每次重连缓存丢失）；(3) SQL 中包含 `LIMIT ?`、子查询等无法缓存的模式，关注 `Plan_cache_unmatched` 指标。

**Q: 缓存大小设置多少合适？**

A: `tidb_prepared_plan_cache_size` 默认 100，对大多数应用足够。如果你的 Prepared Statement 模板数量确实超过 100，设置为模板数的 1.5-2 倍。注意这是一个会话级变量，缓存条目数是指每个连接内的上限。不需要为此分配额外内存——每个缓存计划通常只占几百字节。

**Q: Plan Cache 在 TiDB 中是否默认开启？**

A: TiDB v6.1.0 起 `tidb_enable_prepared_plan_cache` 默认为 `ON`。但前提是应用使用 Prepared Statement——大部分现代 ORM 默认启用，无需额外配置。

**Q: 为什么使用 Prepared Statement 后，EXPLAIN 输出的 `range` 变成了 `[?,?]`？**

A: `EXPLAIN` 默认绑定具体参数值 (`EXPLAIN SELECT ... WHERE user_id = ?` 等同于 `EXPLAIN` 一个普通查询)。使用 `EXPLAIN FORMAT=plan_cache` 可以查看缓存中的参数化计划，其中 range 条件以 `?` 显示。这是符合预期的行为。
