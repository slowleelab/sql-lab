# Region 热点调度与 Split 策略

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB ≥ 4.0" :tags="['Region', '热点调度', 'Split', 'PD调度', 'Hot Region', 'Scatter']" />

## 场景痛点

某实时日志采集系统迁移到 TiDB 后，运维发现：白天业务高峰时段，某个 TiKV 节点的 CPU 持续 100%，但其他节点 CPU 使用率不到 30%。查看 PD Dashboard，发现一个 Region 承载了全集群 60% 的写入流量。

```sql
-- 查看问题表的 Region 分布
SHOW TABLE t_region_test REGIONS;
```

```
+-----------+-----------------------------+-----------------------------+-----------+------------------+-----------+
| REGION_ID | START_KEY                   | END_KEY                     | LEADER_ID | APPROXIMATE_SIZE | APPROXIMATE_KEYS |
+-----------+-----------------------------+-----------------------------+-----------+------------------+-----------+
|      1021 | t_152_                      | t_152_00                    |      1022 |        189000000 |     350000 |
+-----------+-----------------------------+-----------------------------+-----------+------------------+-----------+
```

整个 35 万行表只有一个 Region，且 APPROXIMATE_SIZE 高达 ~189MB（远超默认 96MB 分裂阈值），但自动分裂迟迟未触发——因为分裂是基于 Key 范围而非大小的，而数据写入集中在同一个 Key 范围，导致该 Region 写入热点。

::: warning 真实场景

某社交平台的用户行为日志表，按小时写入用户行为数据。每个整点时刻（如 `12:00:00`），数万台设备同时上报心跳日志，所有写入都命中 `ts = '2026-07-28 12:00:00'` 的 idx_ts 索引条目。该索引条目所在的 Region 成为写入热点，单个 TiKV 节点 CPU 飙至 100%，导致整个集群的写入延迟 P99 从 5ms 恶化到 200ms。PD 热点调度器不断尝试迁移 Leader，但写入速度远超调度速度，热点反复在新 Leader 上形成——这就是"调度跟不上写入"的经典场景。

:::

**本质问题**：TiDB 的 Region 自动分裂机制（默认 96MB 触发）是被动的、有延迟的。当写入倾斜到同一个 Key Range 时，自动分裂无法快速响应，导致单 Region 持续成为瓶颈。这需要**预分裂（SPLIT TABLE）**和**Leader 分散（SCATTER）**两套机制配合解决。

## 问题分析

### Region 是什么

Region 是 TiDB 数据分布和调度的最小单元。每个 Region 负责一段连续的 Key Range，默认大小约 96MB。TiDB 将数据按 Key 排序后切分为多个 Region，每个 Region 包含 3 个副本（默认），通过 Raft 协议保证一致性。

```
┌──────────────────────────────────────────────────────┐
│                    TiDB Cluster                      │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │  TiKV-1  │  │  TiKV-2  │  │  TiKV-3  │  ...      │
│  │          │  │          │  │          │           │
│  │ Region-1 │  │ Region-2 │  │ Region-3 │           │
│  │ (Leader)│  │ (Leader)│  │ (Leader)│            │
│  │ Region-2 │  │ Region-3 │  │ Region-1 │           │
│  │(Follower)│  │(Follower)│  │(Follower)│           │
│  │ Region-3 │  │ Region-1 │  │ Region-2 │           │
│  │(Follower)│  │(Follower)│  │(Follower)│           │
│  └──────────┘  └──────────┘  └──────────┘           │
│                                                      │
│  每个 Region 的 Leader 处理读写请求                    │
│  Follower 仅参与 Raft 复制                             │
└──────────────────────────────────────────────────────┘
```

### bad.sql 暴露的 3 个核心问题

```sql
-- 1. 查看当前表的 Region 分布——所有数据在一个 Region
SHOW TABLE t_region_test REGIONS;

-- 2. 数据倾斜：热点值约有 15 万行（占 50%）
SELECT ts, COUNT(*) AS cnt FROM t_region_test GROUP BY ts ORDER BY cnt DESC LIMIT 10;

-- 3. 集中写入 5 万行热点值——全部路由到同一 Region
INSERT INTO t_region_test (val, ts)
SELECT val, '2026-07-28 12:00:00' FROM t_region_test LIMIT 50000;
```

**问题一：Region 未预分裂**

TiDB 的 Key 编码规则：行 Key 为 `t_{table_id}_r_{row_id}`，索引 Key 为 `t_{table_id}_i_{index_id}_{index_value}_{row_id}`。当 `row_id` 是自增主键时，新插入的行总是追加到表的 Key Range 末尾——这就是为什么自增主键天然会导致最后一个 Region 成为写入热点。建表时没有执行 `SPLIT TABLE`，初始只有一个 Region，所有写入都打在同一个 TiKV 节点上。

**问题二：二级索引热点**

本案例中，写入热点并非来自主键（id 虽是自增，但分散在 30 万行中），而是来自 `idx_ts` 索引。50% 的数据共享同一个 ts 值，这些索引 Key 在 Key 空间中是**相邻**的——都落在同一 Region 的 Key Range 内。即使主键 Region 被自动分裂了，索引 Region 仍然可能是单点热点。

**问题三：Leader 分布不均**

即便 Region 被自动分裂，新 Region 的 Leader 可能仍然落在同一 TiKV 节点上。默认配置下，PD 的 `leader-schedule-limit` 为 4，热点场景下 Leader 迁移速度可能跟不上写入压力。

### 热点形成原理：Key 空间示意图

```
Key 空间（按字典序排列）:

t_152_                                    ← 表前缀
  t_152_r_00000001                        ← row_id=1 的行 Key
  t_152_r_00000002                        ← row_id=2
  ...
  t_152_r_00050000                        ← row_id=50000（Region 1 结束）
  ───────────────────── Region 边界 ─────────────────────
  t_152_r_00050001                        ← Region 2 开始
  ...
  t_152_i_1_2026-07-28 12:00:00_00000001  ← idx_ts 索引 Key（热点值）
  t_152_i_1_2026-07-28 12:00:00_00000002  ← 所有热点 Key 聚集在同一区域
  t_152_i_1_2026-07-28 12:00:00_00000003
  ...（15 万个连续索引 Key 全部在 Region 2 中！）
  ───────────────────── Region 边界 ─────────────────────
  ...
```

## 优化方案

### good.sql

```sql
-- 1. 手动 SPLIT：将表预分裂为 8 个 Region
SPLIT TABLE t_region_test BETWEEN (0) AND (MAXVALUE) REGIONS 8;

-- 2. SCATTER：打散 Region 的 Leader 和 Peer 分布
ALTER TABLE t_region_test SCATTER;

-- 3. 验证效果
SHOW TABLE t_region_test REGIONS;
```

### SPLIT TABLE 工作原理

`SPLIT TABLE ... BETWEEN (0) AND (MAXVALUE) REGIONS 8` 将表的主键范围 [0, MAXVALUE) 均匀划分为 8 段，在每段的分界处创建 Region 边界。执行后，原来 1 个 189MB 的 Region 被切分为 8 个约 23.6MB 的 Region，每个约 4.3 万行。

```
SPLIT 前:  1 个 Region（189MB）  →  写入集中在 1 个 TiKV 节点

SPLIT 后:  8 个 Region（各~24MB） →  写入按主键范围路由到 8 个 Region
  Region 1: row_id [0, 43000]      → TiKV-A
  Region 2: row_id [43001, 86000]  → TiKV-A  ← 可能还在同一节点！
  Region 3: row_id [86001, 129000] → TiKV-B
  ...
```

**关键点**：SPLIT 后 Region 数量增加，但如果多个 Region 的 Leader 都在同一 TiKV 节点，写入压力仍然集中。这就是 SCATTER 的用途。

### SCATTER 工作原理

`ALTER TABLE t_region_test SCATTER` 告诉 PD："把这个表的所有 Region 的 Leader 和 Peer 尽可能分散到不同 TiKV 节点上"。PD 的 scatter-range 调度器会：

1. 为每个 Region 随机选择 Leader 节点（基于节点负载均衡算法）
2. 确保同一 Region 的多个 Peer 不在同一节点（满足副本隔离约束）
3. 异步执行——调度完成后 Leader 分布将趋向均匀

```
SCATTER 前:               SCATTER 后:
  TiKV-A: [Leader×5]        TiKV-A: [Leader×2]
  TiKV-B: [Leader×1]        TiKV-B: [Leader×3]
  TiKV-C: [Leader×2]        TiKV-C: [Leader×3]
  CPU: 90%/15%/30%          CPU: 40%/45%/35%  ← 均衡
```

### 为什么不是等待自动分裂？

TiDB 的自动分裂是**反应式**机制：

| 维度 | 自动分裂 | 手动 SPLIT TABLE |
|------|---------|-----------------|
| 触发时机 | Region 达到 96MB 后 | 建表时或任意时刻 |
| 分裂延迟 | 数秒到数十秒（需 PD 调度） | 即时 |
| 分裂策略 | 在 key range 中间点切分 | 按指定数量均匀切分 |
| 热点预防 | 无法预防——热点已形成 | 主动预防 |
| 适用场景 | 写入均匀分布 | 写入有明显倾斜 |

自动分裂在 Region 达到 96MB 阈值时触发，但从"热点开始"到"分裂完成 + Leader 迁移 + 负载均衡"，整个过程可能需要数分钟——在这之前，热点 TiKV 节点可能已严重过载。

## 深入原理

### Region 调度参数速查表

| 参数 | 默认值 | 作用 | 热点场景调优建议 |
|------|--------|------|-----------------|
| `hot-region-schedule-limit` | 4 | 同时调度的热点 Region 数量上限 | 热点严重时临时调至 8-16，收敛后恢复默认 |
| `hot-region-cache-hits-threshold` | 3 | Region 被识别为热点需连续命中的最小次数 | 调低可更快识别热点（如设为 2），但可能误判 |
| `leader-schedule-limit` | 4 | 同时进行 Leader 迁移操作的数量上限 | 执行 SCATTER 期间可调至 8 加速打散 |
| `region-schedule-limit` | 2048 | 同时进行 Region 迁移的数量上限 | 大量 SPLIT 后保持默认即可 |
| `max-snapshot-count` | 3 | 单个 Store 同时发送/接收 Snapshot 的最大数量 | Region 迁移慢时可调至 6-8 |
| `split-merge-interval` | 1h | 相邻 Region 合并前的最小等待时间 | 热点场景可增大（如 4h），避免刚分裂就被合并 |
| `max-merge-region-size` | 20 (MB) | 超过此大小的 Region 不会参与合并 | 热点场景可减小（如 10MB） |
| `max-merge-region-keys` | 200000 | 超过此 Key 数的 Region 不会参与合并 | 热点场景可减小（如 100000） |

::: tip 参数调整原则

热点严重时优先调整 `hot-region-schedule-limit` 和 `leader-schedule-limit`。这两个参数直接控制调度并发度——上述默认值在极端热点场景下可能不够。调整后观察 PD Dashboard 确认调度速度是否跟上写入速度，收敛后恢复到默认值。

:::

### TiKV 内部：Split 的执行流程

```
① TiDB 接收 SPLIT TABLE 命令
       │
       ▼
② TiDB 计算分界点 Key，向 PD 发送 SplitRegion 请求
       │
       ▼
③ PD 查找目标 Region 的 Leader TiKV 节点
       │
       ▼
④ TiKV Leader 执行 Split：
     · 在当前 Region 的 Key Range 中写入 split_key 标记
     · 触发 Raft Log 复制到 Followers
     · 每个副本独立执行 RocksDB 的 Split（非阻塞写入）
     · 新 Region 继承原 Region 的所有数据（通过共享 SST 文件）
       │
       ▼
⑤ 两个新 Region 上报 PD，PD 为它们分配新的 Peer 位置
       │
       ▼
⑥ PD 调度器开始为新 Region 迁移 Leader / Peer（可能触发 Snapshot）
       │
       ▼
⑦ 客户端路由更新：新的 Region 边界信息通过 gRPC 通知 TiDB Server
```

### SPLIT TABLE 的 3 种语法及适用场景

| 语法 | 示例 | 适用场景 |
|------|------|---------|
| `SPLIT TABLE t BETWEEN (lo) AND (hi) REGIONS N` | `BETWEEN (0) AND (MAXVALUE) REGIONS 8` | 已知数据总量，均匀预分裂 |
| `SPLIT TABLE t BY (value1, value2, ...)` | `SPLIT TABLE t BY (10000, 20000, 30000)` | 已知数据分布，在特定边界切分 |
| `SPLIT TABLE t INDEX idx BETWEEN ...` | 同上但针对索引 Region | 索引有独立热点（如本案例的 idx_ts） |

**注意**：`SHOW TABLE t_region_test REGIONS` 的 `START_KEY` / `END_KEY` 是十六进制编码。要理解某个 Region 管辖哪些行，需要结合 Key 解码规则。TiDB 提供了 `tidb_decode_key()` 函数（v6.3+）辅助调试。

### 针对索引热点的进阶策略

主键 SPLIT 解决了主键 Key 范围的热点，但**索引热点不一定被解决**。本案例中 `idx_ts` 的热点值对应的索引 Key 仍然可能集中在某几个 Region 中。

| 策略 | 效果 | 代价 |
|------|------|------|
| `SPLIT TABLE t INDEX idx BETWEEN ...` | 对索引单独预分裂 | 需要了解索引 Key 的分布 |
| 使用分区表 | 每个分区有独立的 Region 集合，天然隔离热点 | 需要分区键在主键中 |
| `AUTO_RANDOM` / `SHARD_ROW_ID_BITS` | 主键写入散列 | 主键不再是连续递增的（业务需兼容） |
| 业务层打散 ts 值 | 在 ts 上增加毫秒级随机抖动 | 可能影响按时间查询的语义 |

### Region 生命周期与热点调度全景

```
┌─────────────┐    写入量增加     ┌──────────────┐    达到 96MB     ┌──────────────┐
│  新建 Region │ ──────────────► │  持续增长     │ ──────────────► │  自动/手动   │
│  (初始大小)  │                 │  (大小增加)   │                 │  Split       │
└─────────────┘                 └──────────────┘                 └──────┬───────┘
                                                                        │
                                                    ┌───────────────────┘
                                                    ▼
                                            ┌──────────────┐
                                            │  新 Region    │
                                            │  (可能在同一   │
                                            │   TiKV 节点)  │
                                            └──────┬───────┘
                                                   │
                              ┌────────────────────┼────────────────────┐
                              ▼                    ▼                    ▼
                       ┌──────────┐        ┌──────────┐        ┌──────────┐
                       │ Leader   │        │ SCATTER  │        │ 热点调度  │
                       │ 迁移     │        │ 打散     │        │ 自动介入  │
                       │ (PD自动) │        │ (手动触发)│        │ (PD自动) │
                       └──────────┘        └──────────┘        └──────────┘
```

**最佳实践**：主动管理 Region 生命周期——建表阶段按预估数据量执行 `SPLIT TABLE`，然后 `SCATTER` 打散 Leader。后续依赖 PD 的自动调度机制进行微调，而非完全依赖被动调度。

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 95-region-hotspot --ver tidb
```

执行后观察：

- `SHOW TABLE t_region_test REGIONS` 查看初始只有一个或少个 Region
- 执行 `bad.sql` 中的 INSERT 后，观察 `APPROXIMATE_SIZE` 增长
- 执行 `good.sql` 中的 SPLIT TABLE 后，Region 数量变为 8 个
- SCATTER 后 LEADER_ID 分布明显趋于均匀

::: warning 本地复现注意

> **版本要求**：本案例使用的 `SPLIT TABLE ... BETWEEN ...` 语法需 **TiDB ≥ 4.0**。如使用更早版本需改用 `SPLIT TABLE ... BY` 显式指定切分点。

**单节点 TiDB 部署看不到真正的热点效果**。因为：

1. 本地 TiDB (如 `tiup playground`) 通常只有 1 个 TiKV 实例——即使有多个 Region，它们的 Leader 都在这唯一的 TiKV 节点上，所以无法观察到 CPU 负载从单节点转移的效果
2. `SHOW TABLE ... REGIONS` 的 `LEADER_ID` 在所有 Region 上都会指向同一个 store_id
3. 需要至少 **3 个 TiKV 节点** 才能观察 SCATTER 后 Leader 在不同节点间重新分布

**完整的复现步骤（3 节点集群）**：

1. SCATTER 前，多个 Region 的 `LEADER_ID` 指向同一 store_id
2. 执行 `ALTER TABLE t_region_test SCATTER`
3. 等待 5-10 秒，再次 `SHOW TABLE t_region_test REGIONS`
4. 观察 `LEADER_ID` 已分散到不同 store_id

**验证热点是否解决（需要压测）**：

```bash
# 使用 go-ycsb 或 sysbench 在热点 ts 值上持续写入
# 观察各 TiKV 节点的 CPU 使用率，对比 SPLIT/SCATTER 前后
```

:::

## 常见问题

**Q: SPLIT TABLE 后数据需要重新分布吗？**

A: 不需要。SPLIT TABLE 只是创建了新的 Region 边界，数据不会移动。Split 操作利用 RocksDB 的 SST 文件共享机制——新 Region 共享原 Region 的 SST 文件，不需要拷贝数据。后续 Compaction 时数据才会物理分离。

**Q: 什么时候用 SPLIT TABLE，什么时候用分区表？**

A: SPLIT TABLE 适合**数据量已知但分布均匀**的场景；分区表适合**数据按时间等维度天然分层**的场景。两者可以结合：每个分区内再做 SPLIT。分区表的优势是 SQL 可以按分区裁剪（减少扫描范围），SPLIT TABLE 仅影响 Region 分布，不影响查询计划。

**Q: SCATTER 是一次性的还是持久的？**

A: SCATTER 是一次性操作。PD 会尽力将当前 Region 的 Leader/Peer 分散，但随着数据增长、新 Region 产生、节点故障等，Leader 可能再次集中。对于持续写入的大表，可以在 SCATTER 后配合 PD 的 `scatter-range` 调度规则（通过 PD Control 工具 `pd-ctl scheduler add scatter-range`）实现持久化打散。

**Q: 自动分裂的 96MB 阈值可以调整吗？**

A: 可以，通过 PD 配置 `coprocessor.region-split-size` 调整（单位 MB）。但通常不建议调小——更小的 Region 意味着更多的 Region 数量，会增加 PD 调度开销和 Raft 心跳负载。热点问题应优先通过预分裂解决，而非依赖调小自动分裂阈值。

**Q: SHOW TABLE REGIONS 显示的 APPROXIMATE_SIZE 为什么是近似值？**

A: `APPROXIMATE_SIZE` 来自 TiKV 的 RocksDB 的 `GetApproximateSizes` API，是估算值而非精确值。误差来源包括：SST 文件元数据未及时更新、Compaction 过程中数据未完全合并、MVCC 旧版本数据膨胀等。通常误差在 10%-20% 以内，足以判断 Region 是否均衡。

**Q: 热点 Region 调度会阻塞写入吗？**

A: 不会。Region Split 是非阻塞操作——TiKV 在执行 Split 期间正常接受读写请求。Leader 迁移期间有短暂的影响：Leader 切换时（通常 < 1 秒），写入请求会临时失败并自动重试（TiDB 客户端隐式重试）。热点调度器会避免同时在同一个 Region 上执行多个操作，以最小化对写入的影响。
