# 分布式 Sequence 自增方案

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB ≥ 4.0（Sequence CACHE 需 ≥ 4.0）" :tags="['Sequence', '分布式ID', 'AUTO_INCREMENT', 'AUTO_RANDOM', '自增', 'TSO']" />

## 从 MySQL 迁移到 TiDB 后
你的业务需要生成全局唯一的订单号，而且要求**严格递增**以便按时间排序。从 MySQL 迁移到 TiDB 后，你习惯性地用 `AUTO_INCREMENT` 做订单 ID：

```sql
CREATE TABLE t_order (
    id   BIGINT NOT NULL AUTO_INCREMENT,
    ...
    PRIMARY KEY (id)
);
```

但很快你发现了两个问题：

1. **ID 不是严格递增的**。多台 TiDB 实例同时写入时，不同实例可能各自缓存了一段 ID，导致某个较晚提交事务的 ID 反而比另一个实例的旧。回滚的事务 ID 也被永久丢弃。
2. **写入瓶颈**。所有新行的 ID 都落在同一个 Region，TiKV 集群虽然有 3 个节点，但写入 QPS 却受限于单个节点。

你开始寻找替代方案：AUTO_RANDOM 能打散写入，但 ID 不排序；Sequence 支持全局递增，但依赖 TSO。三种方案各有取舍——到底选哪个？

::: warning 真实场景
订单号、流水号、发票号等业务标识需要**全局唯一 + 单调递增 + 可排序**，这是分布式系统中的经典难题。TiDB 提供了三种工具，但没有一种能同时完美满足所有需求：AUTO_INCREMENT（简单但有热点和空洞）、AUTO_RANDOM（无热点但 ID 乱序）、Sequence（严格递增但依赖 TSO）。理解它们的权衡是 TiDB 分布式 ID 选型的关键。
:::

## 问题分析

### bad.sql：AUTO_INCREMENT 在 TiDB 中的局限

```sql
-- AUTO_INCREMENT 由 TiDB Server 层分配，每个 TiDB 实例缓存一段 ID
-- 多 TiDB 实例写入时，ID 跨实例不连续
INSERT INTO t_auto_inc (name, val) VALUES ('test1', 1), ('test2', 2), ('test3', 3);

-- 回滚导致 ID 跳号：事务开始了 ID 已分配，回滚后 ID 被丢弃
BEGIN;
INSERT INTO t_auto_inc (name, val) VALUES ('rollback_test', 999);
ROLLBACK;
INSERT INTO t_auto_inc (name, val) VALUES ('after_rollback', 888);

-- AUTO_INCREMENT 写入热点：所有新 ID 递增落入同一个 Region
SHOW TABLE t_auto_inc REGIONS;
```

### AUTO_INCREMENT 三个核心问题

**问题一：ID 跳号**

TiDB 在事务开始时即分配 AUTO_INCREMENT 值（而非提交时），分配后就不回收。回滚的事务导致 ID 永久丢弃：

```
BEGIN → INSERT (id=8) → ROLLBACK
BEGIN → INSERT (id=9)  ← id=8 被永久跳过了
```

在 `tidb_auto_increment_lock_mode=2` 下，即使是单实例，大量并发事务也可能因为分配提前而出现空洞。回滚越频繁，空洞越大。

**问题二：跨实例乱序（多 TiDB 场景）**

当部署了多个 TiDB Server 实例时，每个实例会缓存一段 AUTO_INCREMENT 范围（默认步长 30000）。实例 A 缓存了 `[1, 30000]`，实例 B 缓存了 `[30001, 60000]`：

- 实例 A 的事务在 t1 时刻插入 id=29999
- 实例 B 的事务在 t2 时刻（t2 > t1）插入 id=30001

如果按 id 排序，实例 B 在"更晚"的时间生成的 id=30001 自然排在 id=29999 后面（正确）。但如果实例 A 的 id=29999 的事务提交更晚，可能发生时间先后的错位。

**问题三：写入热点**

主键递增导致所有新行落入同一个 Region。即使 Region 分裂，热点也会迁移到新分裂的最后一个 Region——**热点随分裂迁移但不消失**。分布式集群的写入能力退回单节点水平。

```
AUTO_INCREMENT 写入热点示意:

  Region-1024: [1, 10000]  ← Leader on TiKV-1
  Region-1026: [10001, 20000]  ← Leader on TiKV-2
  Region-1028: [20001, ∞)      ← Leader on TiKV-3  ← 新写入全部到这里！

  TiKV-3:████████████████  CPU 100%  ← 热点！
  TiKV-1:░░░░░░░░░░░░░░░░  CPU 5%
  TiKV-2:░░░░░░░░░░░░░░░░  CPU 5%
```

### SHOW TABLE REGIONS 结果

```
AUTO_INCREMENT 表:
+-----------+-----------+--------+-----------+-----------------+
| REGION_ID | START_KEY | END_KEY| LEADER_ID | LEADER_STORE_ID |
+-----------+-----------+--------+-----------+-----------------+
|      1024 | t_1_     |        |      1025 |               1 |  ← 仅 1 个 Region
+-----------+-----------+--------+-----------+-----------------+
```

### 为什么需要 Sequence

AUTO_INCREMENT 的局限在于：它是**本地分配**方案，没有全局协调。而 TiDB 拥有 PD（Placement Driver）提供的 **TSO（Timestamp Oracle）**全局时间戳服务——这正是实现严格递增序列的基础。

TiDB 的 `CREATE SEQUENCE` 正是利用 TSO 实现分布式全局递增序列，类似 Oracle 的 Sequence 对象。CACHE 参数借鉴了 Oracle 的 Sequence Cache 设计，通过预分配批量减少 TSO 请求频率。

## 优化方案

### good.sql：Sequence 全局递增序列

```sql
-- 1. 创建 Sequence（订单号场景：从 1000000 起步，CACHE 500 减少 TSO 开销）
CREATE SEQUENCE seq_order_id
    START WITH 1000000
    INCREMENT BY 1
    CACHE 500;

-- 2. 获取 NEXTVAL（每次调用返回下一个值，全局单调递增）
SELECT NEXTVAL(seq_order_id);

-- 3. 在 INSERT 中使用 NEXTVAL
INSERT INTO t_seq (name, val)
VALUES (CONCAT('order_', NEXTVAL(seq_order_id)), 100);

-- 4. 查看 Sequence 定义
SHOW CREATE SEQUENCE seq_order_id;

-- 5. NO CACHE vs CACHE 对比
CREATE SEQUENCE seq_no_cache START WITH 1 INCREMENT BY 1 NO CACHE;
```

### 方案一：Sequence（全局递增，推荐用于订单号场景）

```sql
CREATE SEQUENCE seq_order_id
    START WITH 1000000
    INCREMENT BY 1
    CACHE 500;
```

**原理**：TiDB Sequence 利用 PD 的 TSO 服务实现全局单调递增。每次 NEXTVAL 调用时，TiDB 向 PD 请求分配一个时间戳——TSO 天然保证全局单调递增。

CACHE 参数控制预分配的数量：`CACHE 500` 意味着一次 TSO 请求会预分配 500 个连续的序列值缓存在 TiDB 实例本地。后续 499 次 NEXTVAL 直接从本地缓存读取，不消耗 TSO。第 500 次时重新向 PD 申请下一批。

```
Sequence CACHE 机制:

PD TSO 分配: [1..500] → TiDB Server 本地缓存
  NEXTVAL → 1 (缓存命中)
  NEXTVAL → 2 (缓存命中)
  ... 499 次缓存命中 ...
  NEXTVAL → 500 (缓存命中)
  NEXTVAL → PD 再次请求 [501..1000]
```

**效果**：
- 全局严格单调递增：每次 NEXTVAL 返回的值在全局范围内递增
- TSO 开销可控：CACHE 越大，TSO 请求频率越低（代价是实例重启后缓存值丢失产生空洞）
- 兼容 Oracle Sequence 语法：熟悉 Oracle 的 DBA 可以直接上手

### 方案二：AUTO_RANDOM（高并发写入 + 不需要排序时）

```sql
CREATE TABLE t_auto_rand (
    id   BIGINT NOT NULL AUTO_RANDOM,
    ...
    PRIMARY KEY (id)
);
```

AUTO_RANDOM 通过将 BIGINT 的高 5 位（默认）随机化来打散 ID 分布，不同 shard 前缀的 ID 路由到不同的 Region，写入压力分散到多个 TiKV 节点。代价是 ID 不再排序。

### 方案三：AUTO_INCREMENT（简单低 QPS 场景）

当写入 QPS 较低（单表 < 3000 QPS）时，AUTO_INCREMENT 的热点问题不会成为瓶颈。如果只需要局部递增（单 TiDB 实例），且能容忍空洞和跳号，AUTO_INCREMENT 仍然是最简单的选择。

### 三种方案对比

| | AUTO_INCREMENT | AUTO_RANDOM | Sequence |
|---|---|---|---|
| ID 分配 | TiDB Server 本地步长分配 | shard bits(高位随机) + 自增低位 | PD TSO 全局分配 |
| 全局单调递增 | 不保证 | 不保证 | 严格保证 |
| ID 连续性 | 不连续（回滚/多实例导致空洞） | 不连续（随机高位） | CACHE 下有空洞，NO CACHE 接近连续 |
| 写入热点 | 严重（递增主键） | 无（shard bits 打散） | 严重（递增主键） |
| TSO 依赖 | 不需要 | 不需要 | 每次 NEXTVAL 需要（CACHE 可减少） |
| 排序友好 | 友好（近似递增） | 不友好 | 友好（严格递增） |
| 兼容性 | MySQL 标准 | TiDB 特有 | Oracle/PostgreSQL 风格 |

<ExplainCompare
  :bad="{ global_order: '不保证', write_hotspot: '严重', tso_overhead: '无' }"
  :good="{ global_order: '严格递增', write_hotspot: '严重（同AUTO_INCREMENT）', tso_overhead: 'CACHE可控' }"
  improvement="从无全局协调的本地 ID 分配变为基于 TSO 的全局严格递增序列"
/>

## 避坑指南

::: warning Sequence 使用注意事项

1. **CACHE 越大，重启丢失越多**。CACHE=1000 时，如果 TiDB 实例在消耗到第 300 个值时重启，剩余 700 个值会丢失——这是 CACHE 换性能的必然代价。如果需要严格无空洞，请使用 NO CACHE（但性能会显著下降）。

2. **Sequence 不解决写入热点**。Sequence 生成的是递增 ID，如果用作聚簇主键，新写入仍会集中在最后一个 Region。如果需要解决写热点问题，应使用 AUTO_RANDOM 或将写入表配合 SHARD_ROW_ID_BITS 使用。

3. **Sequence 与事务的关系**。NEXTVAL 一旦调用就消耗了一个序列值，即使事务回滚也不会回收——这与 AUTO_INCREMENT 的跳号行为一致。序列值不是事务性的。

4. **当前限制**。TiDB Sequence 目前不支持 CYCLE（循环），达到 MAXVALUE 后会报错。需要提前监控序列剩余值。

5. **跨 Schema 的 Sequence**。Sequence 是 Schema 级别的对象，在跨 Schema 的场景下需要使用完全限定名（如 `NEXTVAL(mydb.seq_order_id)`）。

6. **降序 Sequence**。可以使用 `INCREMENT BY -1` 创建递减 Sequence，`START WITH 1000000 INCREMENT BY -1` 从 1000000 递减到 1。

7. **TSO 延迟风险**。Sequence 依赖 PD 的 TSO 服务。如果 PD 集群出现网络抖动或不可用，NEXTVAL 会阻塞。CACHE 可以缓解短时间的 PD 不可用（缓存中有预分配的值），但缓存耗尽后仍会阻塞。

8. **多 TiDB 实例的 CACHE 分配**。每个 TiDB 实例独立向 PD 申请 CACHE 批次，CACHE=500 时每个实例缓存 500 个值。如果有 4 个 TiDB 实例，一批 CACHE 申请会分配 2000 个序列值——不同实例的序列范围不重叠，全局仍递增，但跨实例值不连续。

9. **性能关键指标**。`SETVAL(seq, n)` 可以重置序列起始值（通常用于数据迁移后重建序列），但要确保新值大于当前已经分配的最大值，否则会产生重复 ID。

10. **监控建议**。建议监控 Sequence 的当前值（`SELECT LASTVAL(seq)` 获取本会话最后获取的值），在值接近 MAXVALUE 时提前处理。同时监控 PD TSO 的请求延迟，确保 TSO 服务稳定。
:::

## 三方案选型决策树

```
需要严格全局递增的序列号？
├── 是 → 需要排序友好？
│       ├── 是 → Sequence（订单号、流水号、发票号）
│       └── 否 → 极高频写入？
│               ├── 是 → AUTO_RANDOM（日志表、埋点表）
│               └── 否 → Sequence（批量获取，CACHE 减少 TSO）
│
└── 否 → 高并发写入是否导致热点？
        ├── 是 → AUTO_RANDOM（高吞吐写入场景）
        │      └── 需要有序？→ AUTO_INCREMENT + SHARD_ROW_ID_BITS
        └── 否 → AUTO_INCREMENT（低 QPS / 简单场景）
               └── 需要跨实例连续？→ Sequence
```

| 场景 | 推荐方案 | 原因 |
|------|---------|------|
| 订单号/流水号/发票号 | Sequence (CACHE=500) | 需要全局严格递增 + 可排序 + 可读 |
| 用户表（写入 QPS 低） | AUTO_INCREMENT | 简单，QPS 低时热点不显著 |
| 日志表（极高写入 QPS） | AUTO_RANDOM(8) | 写入分散，不需要排序 |
| 需要排序但写入量大的主键 | AUTO_INCREMENT + SHARD_ROW_ID_BITS | 主键有序，隐式 RowID 分散写入 |
| 需要控制序列间隔（如每 10 递增） | Sequence (INCREMENT BY 10) | 保留间隔给多地域或业务扩展 |
| 数据迁移后重置 ID 起点 | Sequence (SETVAL) | 可灵活设置起始值 |

::: tip 核心结论
如果你需要"全局严格递增的数列"——选择 Sequence。如果你需要"高并发写入无热点"——选择 AUTO_RANDOM。如果两者都需要（极端高并发 + 全局有序），可以考虑在应用层使用 Snowflake 或自建号段服务等方案，利用缓存批量分配减少中心化依赖。
:::

## 本地复现

```bash
./scripts/run-case.sh 100-tidb-sequence --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 2 --kv 3
```

启动时使用 2 个 TiDB 实例（`--db 2`）可以更好地观察 AUTO_INCREMENT 跨实例 ID 分配行为，使用 3 个 TiKV 实例（`--kv 3`）可以观察写热点分散效果。

验证关键效果：

```sql
-- 验证 Sequence CACHE 效果
CREATE SEQUENCE test_seq CACHE 100;
SELECT NEXTVAL(test_seq), NEXTVAL(test_seq), NEXTVAL(test_seq);

-- 对比 NO CACHE
CREATE SEQUENCE test_seq_nc NO CACHE;
-- 在高并发场景下观测 TSO 消耗差异
```

要直观看到写热点，可以打开 TiDB Dashboard 的 Key Visualizer：

```bash
tiup dashboard
```

在 Key Visualizer 中分别对 t_auto_inc 和 t_auto_rand 执行批量 INSERT，观察：
- t_auto_inc：明亮的矩形集中于右侧（新增行在最后一个 Region）
- t_auto_rand：多个亮度较低的区域，均匀分布（shard bits 打散写入）
:::
