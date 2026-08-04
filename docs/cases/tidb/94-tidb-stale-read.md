# TiDB Stale Read 历史读优化

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['Stale Read', 'AS OF TIMESTAMP', '历史读', 'MVCC', '快照读']" />

## 高峰报表和写入互相干扰：Stale Read 绕开 Leader
白天高峰时段，订单写入和报表查询在同一个 TiDB 集群上互相干扰。运营团队需要每小时拉一次销售汇总报表，SQL 本身只是一个简单的 `SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale`，但在大量订单写入同时执行时，报表查询经常因锁等待而超时，或者 Leader TiKV 节点 CPU 飙升导致写入延迟抖动。

运维排查后发现：
- 强一致读需要从 Leader 副本读取，所有读和写都压在同一组 Leader 节点上，Follower 节点资源闲置
- 悲观事务模式下，`SELECT ... FROM t_stale WHERE id = x` 可能因为目标行正被写入而等待锁释放
- 每小时上千次报表查询的 TSO 请求加重了 PD 负担

```sql
-- 看似简单的报表查询，在高峰时段可能触发锁等待
SELECT COUNT(*) AS total_items, SUM(qty) AS total_qty, SUM(qty * price) AS total_value
FROM t_stale;
```

::: warning 真实场景

某电商平台的运营后台报表系统从 MySQL 迁移到 TiDB 后，发现每日 10:00 时段的报表查询出现 40% 的超时率。分析发现，该时段正好与秒杀活动的库存写入高峰重合，普通 `SELECT` 的读锁等待导致连锁反应。引入 Stale Read（容忍 5 秒延迟）后，超时率降至 0%，且写入延迟不受影响。

:::

**本质问题**：报表查询需要一致性但不需要"实时"数据——5 秒甚至 1 分钟前的数据已经足够做出业务决策。但强一致读强制以最新 TSO 读取，与写事务竞争同一份资源。

## 问题分析

### TiDB MVCC 与读取机制

TiDB 基于 MVCC（Multi-Version Concurrency Control）存储数据的多个历史版本。每个事务写入时生成一个新的 MVCC 版本，同时保留旧版本（直到 GC 回收）。这意味着：

- 任意过去时间点的数据快照理论上都可通过 MVCC 获取
- 读历史版本不需要加锁——写事务只会创建新版本，不会修改旧版本
- 副本（Leader/Follower）都维护相同的 MVCC 版本历史

### bad.sql（强一致读的 4 个问题点）

```sql
-- 1. 普通 SELECT 从 Leader 读取（强一致读）
SELECT COUNT(*) AS total_items, SUM(qty) AS total_qty, SUM(qty * price) AS total_value
FROM t_stale;

-- 2. 查看当前时间戳
SELECT NOW(), CURRENT_TIMESTAMP();

-- 3. 普通读取被写事务阻塞
-- 会话 A: BEGIN; UPDATE t_stale SET qty = qty + 1 WHERE id = 1;
-- 会话 B: SELECT * FROM t_stale WHERE id = 1; -- 悲观模式下读锁等待

-- 4. 查看默认配置（未启用 Stale Read）
SHOW VARIABLES LIKE 'tidb_read_staleness';
```

### 强一致读的延迟链路

```
TiDB 客户端
    │
    ▼
① 向 PD 请求 TSO  ──────────►  PD Server
    │  延迟: ~0.5ms (RPC)       (集中瓶颈点)
    ▼
② 向 TiKV Leader 发送读取请求 (with TSO)
    │
    ▼
③ Leader 确认 Raft lease（确认自己是有效 Leader）
    │  延迟: ~0-2ms（lease 检查）
    │
    ▼
④ 扫描 MVCC 版本，返回 <= TSO 的最新已提交版本
    │
    ▼
⑤ 如果目标行有未提交的写事务锁:
    │  悲观模式 → 等待锁释放 (tidb_lock_wait_timeout 内)
    │  乐观模式 → 不等待，但读到的可能是旧值
    │
    ▼
⑥ 返回结果给 TiDB → 客户端
```

核心问题：**步骤 ① 到 ⑤ 每一步都可能引入延迟**，尤其是锁等待（步骤 ⑤）在写密集场景下不可控。

## 优化方案

### good.sql

```sql
-- 1. 会话级 Stale Read（容忍5秒延迟）
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;
SET SESSION tidb_read_staleness = '';

-- 2. SQL 语句级：AS OF TIMESTAMP 语法
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale
AS OF TIMESTAMP TIMESTAMPADD(SECOND, -10, NOW());

-- 3. 精确时间点读取（审计场景）
SET @snapshot_ts = '2026-07-01 00:00:00';
SELECT id, item, qty, price FROM t_stale
AS OF TIMESTAMP @snapshot_ts
ORDER BY id LIMIT 20;

-- 4. Stale Read + Follower Read 组合
SET SESSION tidb_replica_read = 'follower';
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;
```

### 为什么 Stale Read 更快

**原理对比**：

```
强一致读:
  写入事务: INSERT/UPDATE/DELETE → 加锁 → 生成新 MVCC 版本 (v100)
  读取事务: SELECT → 请求最新 TSO → 读 v100 → 可能需要等锁释放
  冲突点:   └──────────────── 读写锁竞争 ────────────────┘
  
Stale Read (staleness=-5s):
  写入事务: INSERT/UPDATE/DELETE → 加锁 → 生成新 MVCC 版本 (v100)
  读取事务: SELECT → 请求 TSO 并偏移 -5s → 读 v95 → 不涉及锁
  隔离性:   └─── 写操作影响 v100 ──┘  └─── 读操作访问 v95 ──┘
           （两者操作不同的 MVCC 版本，完全隔离）
```

Stale Read 利用 MVCC 天然的多版本特性：**历史版本不可变，写入事务不影响历史快照，所以读取历史快照不需要等待任何锁**。

### AS OF TIMESTAMP 内部实现

```sql
SELECT * FROM t_stale AS OF TIMESTAMP '2026-07-01 10:00:00' WHERE id < 100;
```

TiKV 处理逻辑：

1. **解析时间戳**：将 `'2026-07-01 10:00:00'` 转为对应的 TSO（Timestamp Oracle）值
2. **MVCC 版本定位**：对于每个 key，在 `CF_WRITE`（Write Column Family）中查找 `commit_ts <= TSO` 的最新 write record
3. **数据读取**：通过 write record 中的指针定位到 `CF_DEFAULT` 中的对应 value
4. **返回**：如果该 key 在指定 TSO 之前不存在（`commit_ts > TSO` 或无记录），该 key 不算入结果

```
TiKV MVCC 存储示意:

Key: t_stable:id=1
  CF_WRITE:
    commit_ts=4567890100 → (write_type: PUT, start_ts=4567890090, pointer)
    commit_ts=4567885000 → (write_type: PUT, start_ts=4567884990, pointer)  ← StaleRead 读此版本
    commit_ts=4567880000 → (write_type: PUT, start_ts=4567879990, pointer)  (已被 GC 回收?)
    
  CF_DEFAULT (实际数据):
    (start_ts=4567890090) → ("Laptop-00001", 100, 2999.99, "2026-07-28 10:00:05")
    (start_ts=4567884990) → ("Laptop-00001",  99, 2999.99, "2026-07-28 09:55:00")  ← 返回此版本
```

### Strong Read vs Stale Read 选型指南

```
你的查询是否必须读到"此时此刻"的最新数据？
│
├── 是 → Strong Read（默认）
│   典型场景:
│    · 库存扣减（不能超卖）
│    · 订单状态查询（刚下单就要看到）
│    · 支付确认（不能重复支付）
│    · 实时对账
│
└── 否 → Stale Read
    典型场景:
     · 报表查询（日报、周报、月报）
     · 数据导出 / ETL
     · 审计查询（对账回顾）
     · 缓存预热 / 数据预加载
     · 批量数据分析
     · 搜索 / 列表页（可容忍秒级延迟）
     
     选择容忍延迟:
     ├── 亚秒级 (1-2s) → tidb_read_staleness = -1 或 -2
     ├── 秒级 (5-10s)  → tidb_read_staleness = -5 或 -10
     ├── 分钟级         → 需确认 GC life time 足够大
     │   ⚠ 默认 tidb_gc_life_time = 10min，不可超出
     └── 精确时间点     → AS OF TIMESTAMP '2026-07-01 10:00:00'
```

## 深入原理

### Stale Read 的三种语法及实现差异

| 语法 | 作用范围 | TSO 来源 | 使用场景 |
|------|---------|---------|---------|
| `SET SESSION tidb_read_staleness = -5` | 会话内所有后续查询 | PD TSO - 5s 偏移 | 会话内多条查询统一延迟 |
| `AS OF TIMESTAMP TIMESTAMPADD(SECOND, -10, NOW())` | 仅当前 SQL | NOW() 转为物理时间 → TSO | 单条 SQL 临时需要历史读 |
| `AS OF TIMESTAMP '2026-07-01 10:00:00'` | 仅当前 SQL | 固定时间 → TSO | 审计/对账精确时间点快照 |

### Stale Read + Follower Read 的协同机制

```
┌──────────────────────────────────────────────────────────┐
│                     TiDB SQL 层                           │
│                                                          │
│  SET tidb_replica_read = 'follower'                      │
│  SET tidb_read_staleness = -5                            │
│                                                          │
│  ① 向 PD 请求 TSO: ts_current = 4567890500               │
│  ② 目标 TSO = ts_current - 5s = 4567890000               │
│  ③ 向 TiKV Follower 发送读请求 (ts=4567890000)            │
│     → Follower 不需要等待 apply 到最新                     │
│     → Follower 只需要该 TSO 对应的 MVCC 版本存在即可       │
│     → 历史版本在所有副本上一致（Raft 已提交）              │
└──────────────────────────────────────────────────────────┘
```

**为什么 Follower Read + Stale Read 是完美组合**：

- Follower Read 分担 Leader 的读负载，但 Follower 可能有 Raft apply 延迟（通常 ~100ms）
- Stale Read 读取的是历史版本（如 5 秒前），天然容忍了 Follower 的 apply 延迟
- 两者结合：**既分担了 Leader 压力，又不要求 Follower 实时同步**

### 三类读取方式延迟分解

```
Strong Read:
  TSO_RPC(0.5ms) + Leader_check(0-2ms) + [锁等待(0~∞)] + Scan
  风险评估: 锁等待不可控

Follower Read:
  TSO_RPC(0.5ms) + apply_wait(0-100ms) + Scan
  风险评估: apply 延迟可控但有波动

Stale Read (Leader):
  TSO_RPC(0.5ms) + Scan
  风险评估: 极低，无明显阻塞点

Stale Read (Follower) — 最优:
  TSO_RPC(0.5ms) + Scan
  风险评估: 极低，且 Leader 不被读请求占用
```

### TiDB 与 MySQL 在"历史读"上的差异

| 特性 | TiDB | MySQL (InnoDB) |
|------|------|---------------|
| 历史数据读取 | `AS OF TIMESTAMP` 原生支持 | 无原生支持（Undo Log 不可直接查询） |
| 读取范围 | 任意表/任意查询 | 无等效功能 |
| 一致性级别 | Snapshot Consistency | 通过 RR 隔离级别模拟（不可自定义时间点） |
| GC 限制 | `tidb_gc_life_time`（默认 10min） | Undo 过期时间（受 undo tablespace 大小限制） |
| 与写入隔离 | 完全隔离（不同 MVCC 版本） | RR 下通过 ReadView 隔离，RC 下可能读到未提交 |
| Follower 读取 | 支持（`tidb_replica_read = 'follower'`） | 只读从库（级联复制延迟不可控） |

::: tip 核心认知

TiDB 的 Stale Read 与 MySQL 的读写分离有本质区别：
- MySQL 读写分离的"读延迟"依赖于主从复制的 binlog 同步速度，延迟不可控（可能 0ms 也可能数十秒）
- TiDB Stale Read 使用 Raft 协议同步，延迟可控（通常 < 100ms），且 `tidb_read_staleness` 允许用户**主动设定**容忍的延迟量
- TiDB 的 AS OF TIMESTAMP 是**精确时间点快照读**，而非"读一个大概滞后的副本"

:::

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 94-tidb-stale-read --ver tidb
```

执行后观察：

- bad.sql 中 `SHOW VARIABLES LIKE 'tidb_read_staleness'` 默认返回空字符串（强一致读）
- good.sql 中设置 `tidb_read_staleness = -5` 后查询返回 5 秒前的数据快照
- `AS OF TIMESTAMP` 语法在 INSERT 之后执行同一查询两次：一次返回插入后的数据（强一致读），一次返回插入前的数据（历史时间点）
- 在 `tidb_replica_read = 'follower'` 下配合 Stale Read，观察 Follower 节点也参与数据读取

::: warning 重要提示

复现时注意：
1. Stale Read 的延迟值不能超过 `tidb_gc_life_time`（默认 10 分钟），否则 TiKV 返回 "GC life time is shorter than transaction duration" 错误
2. 如果指定 `AS OF TIMESTAMP` 的时间点太近（如 1 秒前），可能因 TSO 精度和物理时钟漂移而实际读到当前数据
3. `tidb_read_staleness` 与 `tidb_snapshot` 不能同时设置

:::

## 常见问题

**Q: Stale Read 读到的是"脏数据"吗？**

A: 不是。Stale Read 读到的数据满足 **Snapshot Consistency**——它读取的是某个确定时间点（TSO）对应的一致性快照。该快照中的所有数据都是已提交的（因为只有在 commit_ts <= TSO 时这个数据才可见），不存在"读到一个事务的部分修改"的情况。它只是不保证读到的是"此时此刻最新"的数据，而非读到未提交或无效的数据。

**Q: 如果 Stale Read 的时间点正好处于一次大事务的中间会发生什么？**

A: 不会读到中间状态。MVCC 保证每个版本的 commit_ts 是事务提交时一次性写入的。Stale Read 以 TSO 为基准，只有 `commit_ts <= TSO` 的完整事务修改才可见。如果大事务在 TSO 之后才提交（`commit_ts > TSO`），Stale Read 会读到该事务开始前的状态——Snapshot Consistency 保证不会发生"部分可见"。

**Q: GC 回收了历史版本怎么办？**

A: 查询会报错。TiDB 会返回类似 `GC life time is shorter than transaction duration` 的错误。解决办法：
- 减小 Stale Read 的延迟值（如从 -600 改为 -300）
- 增大 `tidb_gc_life_time`（如从 10m 改为 30m），但这会增加存储开销
- 使用 `AS OF TIMESTAMP` 时确保目标时间在 `SHOW VARIABLES LIKE 'tidb_gc_safe_point'` 之后

**Q: Stale Read 能用于写操作吗（如 INSERT ... SELECT）？**

A: 可以。`INSERT INTO ... SELECT ... AS OF TIMESTAMP ...` 是合法的——SELECT 部分使用历史快照，INSERT 部分正常写入当前时间点。这在数据归档、快照复制等场景中很有用。

**Q: tidb_read_staleness 和 tidb_snapshot 有什么区别？**

A: `tidb_read_staleness` 接受相对时间偏移（如 -5 表示 5 秒前），`tidb_snapshot` 仅接受绝对 TSO 或日期时间。两者功能类似但粒度不同——`tidb_read_staleness` 更直观（"读 5 秒前的数据"），`tidb_snapshot` 更精确（"读 TSO=4567890000 的数据"）。两者不能同时设置，后设置的会覆盖前一个。
