# TiDB 内存控制与 OOM 防护

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['OOM', '内存', '溢出磁盘', 'HashAgg']" />

## 你被监控告警吵醒,失败
周一早上，你被监控告警吵醒——TiDB 集群昨晚凌晨的一条定时报表 SQL 执行失败，业务数仓的日汇总表没有更新。你快速登录数据库，检查慢日志：

```
ERROR 1105 (HY000): Out Of Memory Quota!
```

你注意到这条 SQL 是一个大表（3000 万行）的 `GROUP BY` 聚合，有 50000 个分组，执行时 HashAgg 算子吃了将近 **200MB 内存**——而当前 `tidb_mem_quota_query` 设置为 **100MB**（演示环境特意调低）。你意识到：这不是数据量本身的问题，而是 **TiDB 的内存控制机制**在保护数据库进程的同时，也无情地打断了你的查询。

更棘手的是，同样这条 SQL 在白天偶尔能成功，偶尔又报 OOM。事后你检查监控时发现：白天集群空闲时内存足够，但凌晨恰好有备份任务在跑，总内存紧张，HashAgg 没分到足够空间就被杀掉了。在生产环境中默认 `tidb_mem_quota_query` 是 1GB，而聚合数据量更大时会突破这一阈值。

::: warning 真实场景
在生产 TiDB 集群中，OOM 错误通常不是"表太大"的信号，而是 **并发 + 内存配置** 的组合问题。同一条 SQL 在低并发时可能正常运行，但当 10 个连接同时执行 HashAgg 时，每个都试图申请 1GB=10GB，远超 TiDB Server 的实际可用内存。
:::

## 问题分析

### 核心认知：TiDB 内存控制的三层漏斗

TiDB 对 SQL 执行的内存控制分为三个层级，像漏斗一样逐级收窄：

| 层级 | 控制参数 | 粒度 | 默认值 | 超限行为 |
|------|---------|------|--------|---------|
| 第一层：算子级 | `tidb_mem_quota_query` | 单 SQL 内每个算子的独立内存上限 | **1 GiB** | `tidb_mem_oom_action` 决定 CANCEL/LOG |
| 第二层：会话级 | `tidb_mem_quota_query`（会话 SET） | 单连接内所有 SQL 的内存上限 | 继承全局值 | session 级别覆盖 |
| 第三层：服务器级 | `tidb_server_memory_limit` | TiDB Server 进程总内存上限 | **系统内存的 80%** | GC 回收 → 最终 Kill 内存最大的 SQL |

关键认知：**`tidb_mem_quota_query` 是单 SQL 的内存上限，不是全局限制**。如果有 20 个并发连接同时跑 HashAgg，每个都可能吃满 1GB，总内存压力可达 20GB。

### bad.sql：低内存限额触发 OOM

```sql
-- 1. 查看当前内存限额
SHOW VARIABLES LIKE '%mem%';
SHOW VARIABLES LIKE '%oom%';

-- 2. 故意设置很低的内存限额来模拟 OOM
SET SESSION tidb_mem_quota_query = 104857600; -- 100MB

-- 3. 大 GROUP BY 聚合（HashAgg 内存超限）
-- 50000 个 group，每个 group 需要内存暂存
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;

-- 4. 查看 OOM 相关记录
SHOW VARIABLES LIKE 'tidb_enable_tmp_storage_on_oom';
```

在 EXPLAIN ANALYZE 输出中，HashAgg 算子的 `memory` 列显示 **168.2 MiB**，已超过 100MB 限额。如果 `tidb_enable_tmp_storage_on_oom = OFF`，SQL 会直接报错：

```
ERROR 1105 (HY000): Out Of Memory Quota!
```

#### HashAgg 为何消耗大量内存

TiDB 的 HashAgg 算法流程如下：

1. **构建阶段**：读取 TiKV 返回的每一行数据，按 `GROUP BY` 列计算哈希值
2. **聚合暂存**：在内存 HashTable 中为每个 group 维护 `COUNT/SUM/AVG` 等聚合状态的中间结果
3. **输出阶段**：遍历 HashTable 输出所有 group 的聚合结果

当 group 数量较大（本案例 50,000 个）时，HashTable 的内存占用 = `group 数量 x (聚合函数数量 x 每函数暂存大小 + 列值大小)`。group 数量翻倍，内存消耗几乎线性增长。

### OOM Action 的两种模式

```sql
SHOW VARIABLES LIKE 'tidb_mem_oom_action';
```

| 模式 | 超限时行为 | 适用场景 | 风险 |
|------|-----------|---------|------|
| `CANCEL`（默认） | 立即中断当前 SQL，报错退出 | 测试/开发环境 | 用户查询失败 |
| `LOG` | 只记录日志，SQL 继续执行 | 配合 tmp-storage 的生产环境 | 可能真正耗尽内存导致 TiDB Crash |

## 优化方案

### good.sql：OOM 防护与优化

```sql
-- 1. 启用临时磁盘溢出（默认已启用）
SET GLOBAL tidb_enable_tmp_storage_on_oom = ON;
SHOW VARIABLES LIKE 'tidb_enable_tmp_storage_on_oom';

-- 2. 合理设置内存限额
SET SESSION tidb_mem_quota_query = 1073741824; -- 1GB

-- 3. 监控内存使用（通过 EXPLAIN ANALYZE 查看各算子实际内存）
EXPLAIN ANALYZE SELECT group_id, COUNT(*) AS cnt, AVG(value) AS avg_val, SUM(value) AS total
FROM t_oom_test
GROUP BY group_id
ORDER BY total DESC;

-- 4. 查看 TiDB Server 全局内存使用
SELECT * FROM information_schema.cluster_processlist WHERE command = 'Query';

-- 5. 查看 OOM Action 日志
SHOW VARIABLES LIKE 'tidb_mem_oom_action';
-- LOG 只记录日志不中断，CANCEL 中断当前 SQL

-- 6. 针对高基数 GROUP BY 的分批策略
-- 如果 group 数过大，可先按条件分批聚合
SELECT group_id, COUNT(*), AVG(value), SUM(value)
FROM t_oom_test
WHERE group_id BETWEEN 1 AND 10000
GROUP BY group_id;
```

### 临时磁盘溢出机制（tmp-storage）

当开启 `tidb_enable_tmp_storage_on_oom = ON` 后，TiDB 的内存溢出流程：

```
SQL 执行中 → 算子内存接近 tidb_mem_quota_query
         → 触发 spill-to-disk，将中间结果写入临时文件
         → 继续处理剩余数据，必要时多次溢写
         → 所有数据处理完后，从磁盘读取临时文件合并结果
         → 返回最终结果
```

| 阶段 | 内存操作 | 磁盘操作 | 说明 |
|------|---------|---------|------|
| 正常执行 | HashTable 在内存中构建 | 无 | 速度快 |
| 内存接近限额 | HashTable 部分溢出 | `tmp-storage-path` 写入临时文件 | 速度降低但不会失败 |
| 最终合并 | 从磁盘读取 | 流式读取合并 | 磁盘 I/O 主导 |

在 EXPLAIN ANALYZE 输出中，如果 `disk` 列有非零值且 `operator info` 包含 `spill to disk` 字样，说明该算子发生了磁盘溢写。

### 针对高基数 GROUP BY 的分批策略

当 group 数量极大（如 50000+）时，可采用分段分批聚合：

```sql
-- 方式 1: WHERE 条件分批（适合 group_id 有范围的场景）
SELECT group_id, COUNT(*), AVG(value), SUM(value)
FROM t_oom_test
WHERE group_id BETWEEN 1 AND 10000
GROUP BY group_id;

-- 方式 2: 按 group_id 取模分段
SELECT group_id, COUNT(*), AVG(value), SUM(value)
FROM t_oom_test
WHERE group_id % 5 = 0  -- 分 5 批，取其中一批
GROUP BY group_id;

-- 方式 3: 应用层聚合（适合极其复杂场景）
-- 在应用代码中分段查询，在应用层做二次聚合
```

将 50,000 个 group 拆成 5 批（每批 10,000 个），每批内存消耗从 **~168 MiB 降至 ~33 MiB**，可在极低内存限额下安全执行。

### 关键算子内存消耗参考

| 算子 | 内存消耗因素 | 估算公式（近似） | 典型消耗 |
|------|------------|-----------------|---------|
| **HashAgg** | GROUP BY 基数 | `group 数 x (8+聚合列数x8) 字节` | 50K group ~ 168 MiB |
| **Hash Join** | 较小的表（Build 侧） | `Build 侧行数 x 行宽 x (1.5-2 倍因子)` | 100 万行 x 100B ~ 200 MiB |
| **Sort** | 排序行数 x 行宽 | `行数 x 行宽 + 排序缓冲区` | 10 万行 x 200B ~ 20 MiB |
| **TopN** | N 值 x 行宽 | `N x 行宽 x (2-3 倍)` | Top1000 x 200B ~ 0.6 MiB |

### 监控内存使用的方法

| 方法 | SQL 语句 | 用途 |
|------|---------|------|
| EXPLAIN ANALYZE | `EXPLAIN ANALYZE SELECT ...` | 查看每个算子的实际 `memory` 和 `disk` |
| 慢查询日志 | `SELECT * FROM information_schema.slow_query` | 查看慢 SQL 的 `Mem_max` 字段 |
| 进程列表 | `SELECT * FROM information_schema.cluster_processlist` | 查看当前运行的查询 |
| 内存追踪 | `SHOW VARIABLES LIKE '%mem%'` | 查看所有内存相关参数 |
| TMP 磁盘使用 | 检查 `tmp-storage-path` 目录大小 | 评估溢出频率 |

## 避坑指南

::: warning TiDB 内存控制常见误区

1. **`tidb_mem_quota_query` 不是全局限制**。它限制的是**单条 SQL 内每个算子的内存上限**。20 个并发 HashAgg 可能占用 20 x 1GB = 20GB。全局限制要靠 `tidb_server_memory_limit`。

2. **tmp-storage 需要物理磁盘空间**。`tidb_enable_tmp_storage_on_oom = ON` 只是开关，还需要 `tmp-storage-path` 指向一个有足够空间的目录（建议 **50GB+**）。磁盘满了溢出会失败，SQL 仍会报 OOM。

3. **磁盘溢出不是免费的**。虽然不会中断查询，但溢写到磁盘后查询速度会显著降低——频繁的 disk I/O 可能让原本 1 秒的查询变成 30 秒。溢出是兜底方案，不是优化手段。

4. **CANCEL 模式不适合业务高峰期**。如果生产环境使用 `CANCEL`，峰值时段任何一条复杂 SQL 都可能被中断返回错误，直接影响用户体验。建议生产环境使用 `LOG` 模式配合 tmp-storage。

5. **`tidb_mem_oom_action = LOG` + 无 tmp-storage = 极度危险**。LOG 模式不中断 SQL，但也没有溢出路径——算子会持续吃内存直到 TiDB Server 进程 OOM 崩溃。务必确保 `tidb_enable_tmp_storage_on_oom = ON`。

6. **排序和 Hash Join 也会触发 OOM**。OOM 不仅发生在 HashAgg。大结果集的 `ORDER BY` 排序、大表 `JOIN` 的 Hash Join Build 侧、`IN` 子查询转为 Hash Join 时，都可能因内存不足而 OOM。

7. **不同算子的内存限制是独立的**。一个查询中，Sort 算子有自己的内存配额，HashAgg 也有自己的——它们加起来可以超过 `tidb_mem_quota_query`。TiDB 按算子维度跟踪，而非 SQL 维度累加。

8. **GC 和 `tidb_server_memory_limit` 有延迟**。当总内存超过 `tidb_server_memory_limit_gc_trigger`（默认 70%），Golang GC 会被触发——但 GC 不是瞬间完成的。在 GC 执行期间，内存可能继续增长到 100% 导致 OOM Kill。

:::

### 内存参数配置速查表

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `tidb_mem_quota_query` | 1 GiB | 根据业务峰值调整 | 单条 SQL 的内存上限 |
| `tidb_enable_tmp_storage_on_oom` | ON | ON（生产强烈推荐） | 超限是否溢出到临时磁盘 |
| `tidb_mem_oom_action` | CANCEL | LOG（配合 tmp-storage） | 超限时中断(CANCEL)或记录(LOG) |
| `tmp-storage-path` | `/tmp/<os_user>` | 确保有 **50GB+** 可用空间 | 临时文件落盘路径 |
| `tidb_server_memory_limit` | 80% | 80% | TiDB 进程总内存上限（占系统内存百分比） |
| `tidb_server_memory_limit_gc_trigger` | 70% | 70% | 触发 Golang GC 的内存阈值 |
| `tidb_server_memory_limit_sess_min_size` | 128 MiB | 128 MiB | 触发服务器级内存 Kill 时，单条 SQL 使用的最小内存阈值 |
| `tidb_mem_quota_topn` | 0（无限制） | 可设为 64 MiB | TopN 算子内存限制 |
| `tidb_mem_quota_apply_cache` | 32 MiB | 32 MiB | Apply 算子本地缓存内存限制 |

### TiDB vs MySQL 内存控制对比

对于有 MySQL 经验的 DBA，理解 TiDB 与 MySQL 在内存控制上的差异至关重要：

| 维度 | MySQL | TiDB |
|------|-------|------|
| 内存控制粒度 | 全局 Buffer Pool + 会话 `tmp_table_size` / `sort_buffer_size` | 按算子维度 + `tidb_mem_quota_query` |
| GROUP BY 内存 | `tmp_table_size` 超出后用磁盘临时表 | HashAgg 内存超限 → spill-to-disk（需开启） |
| 会话内存限制 | `max_heap_table_size` / `tmp_table_size` | `tidb_mem_quota_query` 会话级覆盖 |
| OOM 处理 | MySQL 进程可能直接被 OS OOM Killer 杀掉 | TiDB 主动检测超限，CANCEL 或 LOG |
| 磁盘溢出 | `internal_tmp_disk_storage_engine` 自动使用 | 需要显式开启 `tidb_enable_tmp_storage_on_oom` |
| 全局内存 | `innodb_buffer_pool_size` | `tidb_server_memory_limit`（进程级，不包含 TiKV） |

## 本地复现

```bash
./scripts/run-case.sh 90-tidb-memory-oom --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```

执行后观察：
1. 将 `tidb_mem_quota_query` 从默认 1GB 调至 100MB，运行大 GROUP BY 查询
2. 对照 `EXPLAIN ANALYZE` 中 HashAgg 的 `memory` 列与限额的关系
3. 对比 `tidb_enable_tmp_storage_on_oom = ON` vs `OFF` 的行为差异
4. 尝试 `tidb_mem_oom_action = LOG` 配合 tmp-storage 的效果
:::
