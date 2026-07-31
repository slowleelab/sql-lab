# TiDB GC 机制与长事务影响

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['GC', 'MVCC', '长事务', 'safe point', 'Lock View']" />

## 场景痛点

DBA 发现 TiDB 集群的磁盘使用率持续上升，但业务并没有大量写入。检查发现最近执行了一批清理任务——对一张 10 万行的表做了 `DELETE FROM t WHERE status = 0`（约 1 万行），按理说磁盘应该释放空间，但实际上磁盘使用量不减反增。

```sql
-- DBA 执行了数据清理
DELETE FROM t_gc_test WHERE status = 0;  -- 删除约 1 万行
-- 预期: 磁盘空间释放
-- 实际: 磁盘使用率持续增长
```

排查发现问题根源：**应用层有一个持续数小时未关闭的事务**——它在清理任务之前就已 BEGIN，期间一直持有快照，导致 GC Safe Point 无法推进。DELETE 产生的旧版本无法被 GC 回收，加上新写入的数据版本叠加，磁盘空间被双重挤压。

::: warning 真实场景
TiDB 的磁盘空间问题与 MySQL 完全不同。MySQL 中 DELETE 操作立即标记行并放入 undo log，事务提交后 undopurge 回收。而 TiDB 的 DELETE 写入的是"数据版本"而非 undo log，旧版本由后台 GC 周期性清理。**GC Safe Point 是这整个机制的关键闸门——如果它被长事务卡住，旧版本就会大量堆积，磁盘空间不会释放。**
:::

## 核心认知：TiDB GC 与 MySQL undo log 的差异

TiDB 的 GC 机制与 MySQL InnoDB 的 undo purge 在理念上有本质差异，理解这些差异是 DBA 管理 TiDB 的必修课。

### MySQL InnoDB 的旧版本回收

```
MySQL InnoDB:
  UPDATE/DELETE → 写 undo log（回滚段）
  → 事务提交后 undo log 仍保留一段时间（供 MVCC 快照读）
  → InnoDB History List 长度监控
  → purge 线程自动清理
  → DBA 通常无需关注（除非 History List 过长）
```

### TiDB 的旧版本回收

```
TiDB (Percolator 模型):
  UPDATE/DELETE → 写新数据版本（不写 undo log）
  → 旧版本保留在 TiKV 的 RocksDB 中
  → GC Safe Point 标记"在此之前的事务都已结束"
  → GC Worker 周期性扫描 TiKV，删除 Safe Point 之前的旧版本
  → DBA 需要主动关注 GC Safe Point 推进状态
```

### 关键差异对照

| 维度 | MySQL InnoDB | TiDB |
|------|-------------|------|
| 旧版本存储 | undo log（单独表空间） | 数据版本（与数据一起存在 RocksDB） |
| 清理机制 | purge 线程自动处理 | GC Worker 周期性扫描清理 |
| 长事务影响 | undo log 膨胀，History List 堆积 | **GC Safe Point 阻塞，所有旧版本冻结** |
| DBA 关注点 | `History list length`（`SHOW ENGINE INNODB STATUS`） | `tikv_gc_safe_point`（`mysql.tidb` 系统表） |
| 清理粒度 | 事务级别 | 时间戳级别（Safe Point） |
| 磁盘回收 | 文件收缩（ibdata1 / undo 表空间） | RocksDB compaction 逐步回收 |

## 问题分析

### bad.sql：长事务阻塞 GC

```sql
-- bad.sql: 长事务阻塞 GC

-- 1. 查看当前 GC 配置
SHOW VARIABLES LIKE '%gc%';
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_life_time';
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_safe_point';

-- 2. 模拟长事务（在另一个会话保持 BEGIN 不提交）
-- 在 Session A: BEGIN; SELECT * FROM t_gc_test WHERE id = 1;

-- 3. 在主会话做大量 DELETE
DELETE FROM t_gc_test WHERE status = 0;
-- 但这些旧版本无法被 GC 回收，因为 Safe Point 被长事务阻塞

-- 4. 查看当前事务
SELECT * FROM information_schema.cluster_processlist WHERE command != 'Sleep' AND time > 10;

-- 5. 查看锁视图
SELECT * FROM information_schema.data_lock_waits;
```

### 为什么 GC Safe Point 被阻塞

TiDB 的 GC 机制基于时间戳（TSO）。每次事务开始时获取一个 `start_ts`，GC 在决定哪些版本可以回收时需要满足：

```
Safe Point = MIN(
    NOW() - tikv_gc_life_time,
    所有活跃事务的最小 start_ts - 1
)
```

**即：GC Safe Point 永远不能超过任何活跃事务的 start_ts。** 如果有一个事务 start_ts = 100 且一直未提交，Safe Point 最高只能到 99。

```
GC Safe Point 阻塞示意图:

活跃事务               Safe Point 位置
───────────────────────────────────────────────
事务A: start_ts=100    ← 未提交
事务B: start_ts=500    ← 未提交
───────────────────────────────────────────────
Safe Point ≤ 99        ← 不能跨越事务A的start_ts

可以回收的版本: ts < 99
被冻结的版本:   ts 99-499（包括 DELETE 产生的大量旧版本）
```

### MVCC 版本堆积示意

```
正常情况（无长事务）:
  row(k) → [ts=500:当前]  [ts=400:旧]  [ts=300:旧]
                             ↑           ↑
                          Safe Point=450 → GC 回收 ts<450 的版本
  回收后: row(k) → [ts=500:当前]

长事务阻塞:
  row(k) → [ts=500:当前]  [ts=400:旧]  [ts=300:旧]  [ts=200:旧]  [ts=100:旧]
                                                                    ↑
                                                              Safe Point=99（卡住）
  所有旧版本都保留 → 磁盘持续膨胀
```

---

## 优化方案

### good.sql：GC 优化与长事务治理

```sql
-- good.sql: GC 优化与长事务治理

-- 1. 调整 GC 配置
UPDATE mysql.tidb SET variable_value = '24h' WHERE variable_name = 'tikv_gc_life_time';

-- 2. 查看 GC 状态和 Safe Point
SELECT * FROM mysql.tidb WHERE variable_name IN ('tikv_gc_safe_point', 'tikv_gc_run_interval', 'tikv_gc_life_time');

-- 3. 设置事务超时，防止长事务
SET SESSION tidb_idle_transaction_timeout = 300;
SET SESSION tidb_max_execution_time_ms = 10000;  -- 10 秒（TiDB 7.x；MySQL 变量 max_execution_time 在 TiDB 中不生效）

-- 4. 查看 GC 历史
SELECT * FROM mysql.tidb WHERE variable_name LIKE 'tikv_gc%';

-- 5. 合理的事务设计：短事务 + 分批处理
-- 将大量 DELETE 拆分为小批次（与 bad.sql 同条件 status=0）
DELETE FROM t_gc_test WHERE status = 0 LIMIT 1000;
-- 每批次提交后 GC 可推进
```

### 原理

**方案一：调整 GC 参数**

`tikv_gc_life_time` 控制历史版本保留时长，默认 10m。对于生产环境，建议设置为 24h——既保证快照读（AS OF TIMESTAMP）可用，又避免版本无限堆积。

**方案二：事务超时防护**

- `tidb_idle_transaction_timeout`：事务空闲超时。连接在事务中空闲超过指定秒数，自动回滚。防止 "BEGIN 后忘记 COMMIT" 导致的长事务。
- `tidb_max_execution_time_ms`（TiDB 7.x；MySQL 8.0 的 `max_execution_time` 在 TiDB 中不生效）：单条 SQL 最大执行时间（毫秒）。防止大 SQL 撑出长事务。

**方案三：分批处理**

将大 DELETE 拆分为 `LIMIT 1000` 的小批次，每批提交后 GC Safe Point 立即可以推进到该批提交的时间戳。GC 渐进式回收旧版本，不会出现版本集中堆积。

### 对比

| | 批量 DELETE（一次性，bad） | 分批 DELETE（LIMIT 1000，good） |
|---|---|---|
| 单事务时长 | 长（数分钟-数小时） | 短（毫秒级） |
| GC 阻塞 | **阻塞 Safe Point** | 不影响 |
| 历史版本堆积 | 大量集中堆积 | 分散回收，不堆积 |
| 锁持有 | 长时间持锁 | 短暂持锁 |
| 磁盘释放 | 延迟（等 GC 追上） | 渐进释放 |
| 中断恢复 | 代价大（回滚耗时长） | 随时可暂停/恢复 |

<ExplainCompare
  :bad="{ gc_blocked: 'Safe Point 被长事务卡住', version_pile_up: '旧版本集中堆积', disk_usage: 'DELETE 后不降反增' }"
  :good="{ gc_healthy: 'Safe Point 平稳推进', version_clean: '分批提交渐进回收', disk_usage: '逐步释放' }"
  improvement="从 Safe Point 阻塞变为渐进式推进，DELETE 后空间及时回收"
/>

---

## 避坑指南

::: warning 注意事项

1. **不要随意调大 GC life_time**。`tikv_gc_life_time` 越大，历史版本保留越久，磁盘占用越高。只有在需要频繁使用 `AS OF TIMESTAMP` 快照读的场景才需要调大。生产环境建议不超过 24h。

2. **长事务要及时 kill**。定期通过 `CLUSTER_PROCESSLIST` 或 TiDB Dashboard 检查长时间运行的事务。发现异常长事务后使用 `KILL TIDB <connection_id>` 终止。

3. **不要将 `tikv_gc_life_time` 设得比事务超时还短**。如果 GC life_time = 1m 而你的业务事务可能持续 5m，事务执行期间它引用的版本可能已被 GC 清理，引发 "GC life time is shorter than transaction duration" 错误。

4. **监控 GC Safe Point 推进**。定期检查 `mysql.tidb` 表中 `tikv_gc_safe_point` 是否正常推进。如果发现 Safe Point 长时间不动，立刻排查是否有长事务。

5. **GC 参数调整要慎重**。`tikv_gc_concurrency` 调得太大可能导致 TiKV 在高负载时段额外消耗 CPU 做 GC。建议在低峰期调参，并监控 TiKV CPU 使用率。

6. **DDL 期间 GC 行为特殊**。TiDB DDL 操作也可能引用历史版本。在线 DDL 期间如果 GC life_time 太短，DDL 可能失败。

7. **使用 TiDB Dashboard 可视化监控**。Dashboard 中的 GC 页面可以直观看到 GC 状态、Safe Point 位置、GC 耗时等指标，比 SQL 手动查询更方便。
:::

---

## GC 参数配置指南

| 参数 | 默认值 | 推荐值 | 适用场景 |
|------|--------|--------|---------|
| `tikv_gc_life_time` | `10m` | `24h` | 常规业务，偶尔使用快照读 |
| `tikv_gc_run_interval` | `10m` | `10m` | 所有场景（保持默认） |
| `tikv_gc_concurrency` | `2` | `2-4` | 大规模集群或数据变更频繁时适当调大 |
| `tikv_gc_scan_lock_mode` | `LEGACY` | `PHYSICAL`（v5.0+） | 升级到 v5.0+ 后建议切换 |
| `tikv_gc_enable_compaction_filter` | `false` | `true`（v5.0+） | 写入密集型场景，利用 compaction 辅助回收 |
| `tikv_gc_auto_concurrency` | `true` | `true` | 所有场景（让 TiDB 自动调整） |
| `tidb_idle_transaction_timeout` | `0`（不限制） | `300` | 所有在线业务（防止忘记 COMMIT） |
| `tidb_max_execution_time_ms` | `0`（不限制） | `10000` | 在线 OLTP 业务（防止慢 SQL 撑出长事务，TiDB 7.x 变量名） |

---

## 本地复现

```bash
# 启动 TiDB 集群
tiup playground v7.5.1 --db 1 --kv 3

# 运行本案例
./scripts/run-case.sh 88-tidb-gc --ver tidb

# 跳过造数据重跑
./scripts/run-case.sh 88-tidb-gc --ver tidb --no-seed
```

执行后观察：
- `SHOW VARIABLES LIKE '%gc%'` 查看 GC 相关变量
- `mysql.tidb` 系统表中 `tikv_gc_safe_point` 的推进情况
- 长事务阻塞时 Safe Point 是否停滞
- 分批删除后 Safe Point 是否立即推进

::: tip 模拟长事务阻塞实验

在本地复现时，可以通过两个终端模拟长事务阻塞 GC：

**终端 1（模拟长事务）**：
```sql
BEGIN;
SELECT * FROM t_gc_test WHERE id = 1;
-- 保持此事务不提交
```

**终端 2（执行 DELETE + 查看 Safe Point）**：
```sql
DELETE FROM t_gc_test WHERE status = 0;
COMMIT;

-- 反复执行以下查询，观察 Safe Point 是否推进
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_safe_point';
```

只有当终端 1 的 `BEGIN` 被 `COMMIT` 或 `ROLLBACK` 后，Safe Point 才会恢复推进，旧版本才会被 GC 回收。
:::
