# EXPLAIN 参考结果 - good.sql（使用 Plan Cache）

## TiDB v7.5.1（10 万行）

---

### 1. 启用 Plan Cache

```sql
SET GLOBAL tidb_enable_prepared_plan_cache = ON;
SHOW VARIABLES LIKE 'tidb_enable_prepared_plan_cache';
```

```
+-------------------------------------+-------+
| Variable_name                       | Value |
+-------------------------------------+-------+
| tidb_enable_prepared_plan_cache     | ON    |
+-------------------------------------+-------+
```

---

### 2. 设置 Plan Cache 容量

```sql
SET GLOBAL tidb_prepared_plan_cache_size = 100;
SHOW VARIABLES LIKE 'tidb_prepared_plan_cache%';
```

```
+----------------------------------+-------+
| Variable_name                    | Value |
+----------------------------------+-------+
| tidb_prepared_plan_cache_size    | 100   |
| tidb_prepared_plan_cache_monitor | OFF   |
+----------------------------------+-------+
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `tidb_enable_prepared_plan_cache` | `ON`（TiDB v6.1+） | 是否启用 Prepared Plan Cache |
| `tidb_prepared_plan_cache_size` | `100` | 最多缓存多少个不同 SQL 模板的执行计划 |
| `tidb_prepared_plan_cache_monitor` | `OFF` | 是否启用监控（默认关闭以减少开销） |

---

### 3. 使用 Prepared Statement 并多次执行

```sql
PREPARE stmt FROM 'SELECT id, name, score FROM t_plan_cache WHERE user_id = ?';

SET @uid = 100;
EXECUTE stmt USING @uid;
-- 第一次执行: Plan Cache MISS → 优化 → 缓存执行计划

SET @uid = 200;
EXECUTE stmt USING @uid;
-- 第二次执行: Plan Cache HIT → 直接复用，跳过优化

SET @uid = 300;
EXECUTE stmt USING @uid;
-- 第三次执行: Plan Cache HIT → 直接复用

DEALLOCATE PREPARE stmt;
```

执行结果（每行数据示例）：
```
+------+---------+-------+-------+
| id   | name    | score |       |
+------+---------+-------+-------+
|  101 | user_101|    42 |       |
+------+---------+-------+-------+
(三次 EXECUTE 分别返回不同 user_id 对应的行)
```

---

### 4. Plan Cache 命中统计

```sql
SHOW GLOBAL STATUS LIKE 'Plan_cache%';
```

```
+--------------------------+-------+
| Variable_name            | Value |
+--------------------------+-------+
| Plan_cache_hit           | 2     |
| Plan_cache_hit_select    | 2     |
| Plan_cache_hit_point_get | 0     |
| Plan_cache_miss          | 1     |
| Plan_cache_unmatched     | 0     |
| Plan_cache_evicted       | 0     |
| Plan_cache_memory_usage  | 512   |
+--------------------------+-------+
```

| 状态变量 | 值 | 说明 |
|---------|-----|------|
| `Plan_cache_hit` | `2` | 总命中次数 = 第二次 + 第三次 EXECUTE |
| `Plan_cache_hit_select` | `2` | SELECT 类型命中（区分 batch/point_get） |
| `Plan_cache_miss` | `1` | 第一次 EXECUTE 未命中，触发优化和缓存 |
| `Plan_cache_unmatched` | `0` | 无因参数化限制导致的未匹配 |
| `Plan_cache_evicted` | `0` | 无淘汰（缓存数量未超过 100 上限） |
| `Plan_cache_memory_usage` | `512` | 缓存占用约 512 字节 |

---

### 5. 查看当前缓存的计划

```sql
SELECT * FROM information_schema.cluster_plan_cache;
```

```
+-----------------------+---------------------+-----------+------+
| SQL_DIGEST            | PLAN_DIGEST         | MEMORY_USAGE | EXECUTIONS |
+-----------------------+---------------------+--------------+------------+
| 42a1c8aae6f133e9...   | 92c3f3b6e1a0d5...   | 512          | 3          |
+-----------------------+---------------------+--------------+------------+
```

| 字段 | 说明 |
|------|------|
| `SQL_DIGEST` | SQL 模板的哈希值（参数化后的 SQL 指纹） |
| `PLAN_DIGEST` | 执行计划的哈希值 |
| `MEMORY_USAGE` | 该缓存项占用的内存（字节） |
| `EXECUTIONS` | 该缓存计划被执行的次数 |

---

### 6. EXPLAIN FORMAT=plan_cache

```sql
EXPLAIN FORMAT=plan_cache SELECT id, name, score FROM t_plan_cache WHERE user_id = ?;
```

```
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| id                            | estRows  | task      | access object                  | operator info                     |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
| IndexLookUp_7                 | 10.00    | root      |                                |                                   |
| ├─IndexRangeScan_5(Build)     | 10.00    | cop[tikv] | table:t_plan_cache, index:idx_user | range:[?,?], keep order:false     |
| └─TableRowIDScan_6(Probe)     | 10.00    | cop[tikv] | table:t_plan_cache             | keep order:false                  |
+-------------------------------+----------+-----------+--------------------------------+-----------------------------------+
```

注意 `operator info` 中 `range` 显示为 `[?,?]` 而非具体值——这是 `FORMAT=plan_cache` 的特征，显示的是缓存中的参数化计划而非绑定具体参数后的计划。

---

### 7. Plan Cache 的生命周期

```
PREPARE stmt → 注册 SQL 模板
     │
EXECUTE stmt (第1次) → Plan Cache MISS
     │                    │
     │                    ├─ 解析 SQL 模板
     │                    ├─ 逻辑优化
     │                    ├─ 物理优化
     │                    ├─ 生成执行计划
     │                    ├─ 存入 Plan Cache（以 SQL_DIGEST 为 key）
     │                    └─ 绑定参数并执行
     │
EXECUTE stmt (第2次) → Plan Cache HIT
     │                    │
     │                    ├─ 根据 SQL_DIGEST 查找缓存
     │                    ├─ 验证计划有效性（统计信息、schema 版本等）
     │                    ├─ 直接绑定新参数
     │                    └─ 跳过优化阶段，直接执行
     │
DEALLOCATE PREPARE stmt → 释放语句句柄（缓存计划不一定立即清除）
```

---

### 8. Plan Cache 的局限性

以下场景**无法使用** Plan Cache（即使使用 Prepared Statement）：

| 限制场景 | 示例 | 原因 |
|---------|------|------|
| ORDER BY 含变量表达式 | `ORDER BY col LIMIT ?` 的复杂形式 | 排序键依赖于变量，无法提前确定 |
| LIMIT/OFFSET 含变量 | `LIMIT ?, ?` | 限制值影响执行策略选择 |
| 包含子查询 | `WHERE col IN (SELECT ...)` | 子查询可能独立变化 |
| SQL 中包含 `IGNORE_PLAN_CACHE()` hint | `SELECT /*+ IGNORE_PLAN_CACHE() */ ...` | 显式禁用缓存 |
| 用户变量参与计算 | `WHERE col > @var + 1` | 变量表达式导致计划不确定性 |
| 统计信息过期 | — | TiDB 检测到统计信息变更后会清除对应缓存 |

```sql
-- 示例：包含 LIMIT 变量的 Prepared Statement 无法使用 Plan Cache
PREPARE stmt_limited FROM 'SELECT id, name FROM t_plan_cache WHERE city = ? LIMIT ?';
SET @city = 'Beijing';
SET @lim = 10;
EXECUTE stmt_limited USING @city, @lim;
-- Plan_cache_unmatched 计数器会增加
```

---

### 性能收益估算

在高并发 OLTP 场景下，Prepared Statement + Plan Cache 的优化器 CPU 节省：

| 场景 | 普通 SQL（无缓存） | Prepared Statement（有缓存） | 节省 |
|------|-------------------|---------------------------|------|
| 单次查询优化耗时 | ~0.3-1ms | 首次 ~0.3-1ms，后续 <0.05ms | 80-95% |
| 1000 QPS 优化器 CPU | ~300-1000ms/s | ~50-200ms/s | 30-50% |
| 10,000 QPS 优化器 CPU | ~3-10 核 | ~0.5-2 核 | 大幅降低 |

核心收益在于：高并发下大量相同模式的查询共享同一个执行计划，优化器从瓶颈路径中移除。
