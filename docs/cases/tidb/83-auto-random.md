# AUTO_RANDOM 避免写热点

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['AUTO_RANDOM', '写热点', 'Region', '分布式ID']" />

## 单 TiKV 节点 CPU 100%：AUTO_INCREMENT 写热点
你负责的业务刚从 MySQL 迁移到 TiDB，一开始跑得还不错。但随着流量增长，你发现在促销活动期间，写入 QPS 怎么也上不去——监控显示**某个 TiKV 节点的 CPU 一直是 100%**，而其他两个节点几乎空闲：

```
TiKV-1: ████████████████  CPU 100%  ← 热点！
TiKV-2: ░░░░░░░░░░░░░░░░  CPU 8%
TiKV-3: ░░░░░░░░░░░░░░░░  CPU 5%
```

你排查后发现，所有写入压力都集中在了一张"订单表"上，而这张表的主键用的是 `AUTO_INCREMENT`：

```sql
CREATE TABLE t_order (
    id    BIGINT NOT NULL AUTO_INCREMENT,
    ...
    PRIMARY KEY (id)
);
```

你疑惑了：TiDB 不是号称分布式数据库吗？为什么加了三个 TiKV 节点，写入却只打到一个节点上？

::: warning 真实场景
这不是 TiDB 的 bug，而是 AUTO_INCREMENT 在分布式环境中的天然缺陷。主键连续递增导致所有新行落入同一个 Region，Region 的 Leader 又固定在单个 TiKV 节点上——分布式集群实际上退化成了单机写入。几乎所有从 MySQL 迁移到 TiDB 的业务都会踩这个坑。
:::

## 问题分析

### bad.sql：AUTO_INCREMENT 的写热点

```sql
-- 1. 查看 AUTO_INCREMENT 表的 Region 分布
SHOW TABLE t_auto_inc REGIONS;

-- 2. 批量 INSERT 演示——所有新写入路由到同一个 Region
INSERT INTO t_auto_inc (name, val)
SELECT CONCAT('user_', seq), FLOOR(RAND() * 1000)
FROM (SELECT @rownum := @rownum + 1 AS seq FROM
      (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
      (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
      (SELECT @rownum := 0) r
) t LIMIT 1000;

-- 3. 再次查看——1000 行追加后仍只有 1 个 Region
SHOW TABLE t_auto_inc REGIONS;
```

### SHOW TABLE REGIONS 结果

```
AUTO_INCREMENT 表:
+-----------+-----------+--------+-----------+-----------------+
| REGION_ID | START_KEY | END_KEY| LEADER_ID | LEADER_STORE_ID |
+-----------+-----------+--------+-----------+-----------------+
|      1024 | t_1_     |        |      1025 |               1 |  ← 仅 1 个 Region！
+-----------+-----------+--------+-----------+-----------------+
```

### 为什么慢

问题根源在于 TiDB 的数据分布机制：

1. **TiDB 按主键范围切分 Region**。AUTO_INCREMENT 生成的主键是连续递增的（1001, 1002, 1003...），所有新行都落在同一个 Range 区间内。

2. **新写入永远命中"最后一个 Region"**。因为新 ID 越来越大，它们只会落入当前 Key Range 最大的 Region。即使 Region 达到 96MB 后分裂成两个，写入热点也只会迁移到新分裂出的那个 Region——**热点随分裂迁移，但永远不会消失**。

3. **Region 的 Leader 在单节点上**。每个 Region 的 Leader 只在一个 TiKV 节点，所有写入都通过 Leader 进行。热点 Region 的 Leader 所在节点就会成为瓶颈。

```
AUTO_INCREMENT 写入热点示意:

  ID: 1001 ─┐
  ID: 1002 ─┤
  ID: 1003 ─┼─→ Region-1024 (Leader on TiKV-1)  ← 所有写入打到这里！
  ID: 1004 ─┤
  ID: 1005 ─┘

  TiKV-1:████████████████  CPU 100%
  TiKV-2:░░░░░░░░░░░░░░░░  CPU 5%
  TiKV-3:░░░░░░░░░░░░░░░░  CPU 5%
```

::: tip 核心认知
TiDB 是分布式数据库，但 AUTO_INCREMENT 让写入退化成了**单机行为**。你加了 N 个 TiKV 节点，写入吞吐并不会线性扩展——因为所有写入都落在一个 Region 的 Leader 上。
:::

## 优化方案

### good.sql：AUTO_RANDOM 和 SHARD_ROW_ID_BITS

```sql
-- 1. AUTO_RANDOM 表的 Region 分布（ID 高位被随机化，分散到多个 Region）
SHOW TABLE t_auto_random REGIONS;

-- 2. SHARD_ROW_ID_BITS 表的 Region 分布
SHOW TABLE t_shard_row REGIONS;

-- 3. 使用 AUTO_RANDOM 批量插入（写入分散到多个 TiKV 节点）
INSERT INTO t_auto_random (name, val)
SELECT CONCAT('user_', seq), FLOOR(RAND() * 1000)
FROM (SELECT @rownum := @rownum + 1 AS seq FROM ... ) t LIMIT 1000;

-- 4. SHARD_ROW_ID_BITS 表批量插入
INSERT INTO t_shard_row (name, val)
SELECT CONCAT('user_', seq), FLOOR(RAND() * 1000)
FROM (SELECT @rownum := @rownum + 1 AS seq FROM ... ) t LIMIT 1000;
```

### 方案一：AUTO_RANDOM（主键场景，推荐）

```sql
CREATE TABLE t_auto_random (
    id    BIGINT NOT NULL AUTO_RANDOM,   -- 仅替换 AUTO_INCREMENT 为 AUTO_RANDOM
    name  VARCHAR(50) NOT NULL,
    val   INT    NOT NULL,
    PRIMARY KEY (id)
);
```

**原理**：AUTO_RANDOM 将 BIGINT 的最高几位（默认 5 位，可配 1-15）用作 **shard bits**。这几位是随机生成的，导致 ID 不再连续递增：

```
AUTO_RANDOM ID 结构（BIGINT，默认 shard bits=5）:

|<-- shard bits (5位) -->|<-- auto-increment bits (59位) -->|

shard bits = hash(随机值)  →  决定路由到哪个 Region（最多 2^5 = 32 个分片）
auto-increment bits        →  保证 ID 唯一性
```

**效果**：不同的 INSERT 可能生成不同 shard 前缀的 ID，被路由到不同的 Region，写入压力被打散到多个 TiKV 节点：

```
AUTO_RANDOM 写入分散示意:

  ID: 0x1A3B... → Region-A (Shard=0x1A, Leader on TiKV-1)
  ID: 0x7F2C... → Region-B (Shard=0x7F, Leader on TiKV-2)  ← 写入打散！
  ID: 0x3E8D... → Region-C (Shard=0x3E, Leader on TiKV-3)
  ID: 0x9B01... → Region-D (Shard=0x9B, Leader on TiKV-1)

  TiKV-1:████████░░░░░░░░  CPU 40%
  TiKV-2:████████░░░░░░░░  CPU 40%
  TiKV-3:████████░░░░░░░░  CPU 40%
```

### 方案二：SHARD_ROW_ID_BITS（非主键或非聚簇表场景）

```sql
CREATE TABLE t_shard_row (
    id    BIGINT NOT NULL AUTO_INCREMENT,  -- 仍用 AUTO_INCREMENT
    name  VARCHAR(50) NOT NULL,
    val   INT    NOT NULL,
    PRIMARY KEY (id)
) SHARD_ROW_ID_BITS = 4;   -- 对隐式 RowID 进行 shard，2^4=16 个分片
```

**适用场景**：当你**不能改主键定义**（例如主键有业务含义，不适合用 AUTO_RANDOM），但仍想避免写入热点。

**原理**：TiDB 内部每行都有一个隐式的 `_tidb_rowid`。`SHARD_ROW_ID_BITS = 4` 会将 `_tidb_rowid` 的高 4 位随机化，从而打散数据的物理分布。主键仍然由 `AUTO_INCREMENT` 生成，对外接口不变。

### 方案对比

| | AUTO_INCREMENT | AUTO_RANDOM | SHARD_ROW_ID_BITS |
|---|---|---|---|
| 主键类型 | 自增整数 | 随机高位+自增低位 | 仍为自增整数 |
| ID 连续性 | 连续递增 | **不连续、不保证递增** | 连续递增 |
| 写入分散 | 单 Region 热点 | 多 Region 并发写入 | 多 Region 并发写入 |
| 写入吞吐 | 受单 TiKV 限制 | **线性扩展** | **线性扩展** |
| 适用场景 | 单机 MySQL | 分布式高并发写入 | 不能改主键定义时 |
| 对业务的影响 | 无 | ID 不再有序 | 无（主键对外不变） |

<ExplainCompare
  :bad="{ regions: '1个', leader_distribution: '单节点', write_throughput: '单机瓶颈' }"
  :good="{ regions: '最多32个（默认shard bits=5）', leader_distribution: '多节点均摊', write_throughput: '线性扩展 3-10x' }"
  improvement="写入压力从单节点热点变为多节点均摊，吞吐线性扩展"
/>

## 避坑指南

::: warning AUTO_RANDOM 使用注意事项

1. **AUTO_RANDOM 生成的 ID 不连续、不保证递增顺序**。如果你用 ID 做时间排序（例如"最新的订单在前"），AUTO_RANDOM 不能满足需求。这类场景可以保留 AUTO_INCREMENT 主键 + 一个时间列做排序索引。

2. **AUTO_RANDOM 只适用于主键是 BIGINT 的表**。如果主键是 INT 或其他类型，不能用 AUTO_RANDOM。可以考虑 SHARD_ROW_ID_BITS 方案。

3. **AUTO_RANDOM 不能与 AUTO_INCREMENT 混用**。同一列只能选择一种。而且 AUTO_RANDOM 不允许通过 `INSERT ... VALUES (id, ...)` 显式指定 ID 值（除非启用 `@@allow_auto_random_explicit_insert`）。

4. **shard bits 数量选择**：默认 5 位（最多 32 个分片）。如果你的写入压力非常大（几十万 QPS），可以调大到 8-10 位。但 shard bits 越大，ID 可用的自增位数越少——BIGINT 只有 64 位，shard bits 占高位，剩下的才是自增位。建议不超过 10 位。

5. **SHARD_ROW_ID_BITS 对查询的影响**：`SHARD_ROW_ID_BITS` 打散的是隐式 `_tidb_rowid`，不影响主键索引。但如果你经常做全表扫描，数据被分散到更多 Region 反而有助于并行扫描。

6. **Region 热点监控**：可以通过 TiDB Dashboard 的 **Key Visualizer（热力图）** 直观看到写入热点。亮色的矩形区域就是热点 Region。

7. **批量插入也要注意**：即使使用 AUTO_RANDOM，如果一次 INSERT 的行数很大，也可能在短时间内形成局部热点。建议将大批量写入拆分为多个小批次，每批几千行。

8. **AUTO_RANDOM 允许的显式插入**：默认禁止显式指定 AUTO_RANDOM 列的值。如果需要（如数据迁移），可以设置 `SET @@allow_auto_random_explicit_insert = 1;`，但要注意这可能导致 ID 冲突。
:::

## AUTO_INCREMENT vs AUTO_RANDOM 选型指南

| 场景 | 推荐方案 | 原因 |
|------|---------|------|
| 订单表（需要按 ID 排序） | AUTO_INCREMENT + SHARD_ROW_ID_BITS | ID 保持有序，写入分散 |
| 日志表（只追加，不关心 ID 顺序） | AUTO_RANDOM | 吞吐最高 |
| 用户表（写入量不大） | AUTO_INCREMENT 即可 | 写入 QPS 低，热点不显著 |
| 流水表（极高写入 QPS） | AUTO_RANDOM(8) | 更多 shard bits 应对更高并发 |
| 关联表（中间表，无业务主键） | AUTO_RANDOM | 最简单 |
| 数据迁移/同步场景 | AUTO_RANDOM + allow_auto_random_explicit_insert | 迁移时保留原 ID |
| MySQL 兼容性要求高的场景 | AUTO_INCREMENT + SHARD_ROW_ID_BITS | 主键行为与 MySQL 一致 |

::: tip 什么时候不需要 AUTO_RANDOM
如果单表写入 QPS 低于 3000，AUTO_INCREMENT 的热点问题通常不会成为瓶颈——TiKV 单节点处理能力足够。只有当写入 QPS 持续超过单节点极限时才需要 AUTO_RANDOM 或 SHARD_ROW_ID_BITS。
:::

## 本地复现

```bash
./scripts/run-case.sh 83-auto-random --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 3
```

注意启动时至少指定 3 个 TiKV 节点（`--kv 3`），否则无法观察到热点分散效果。

要直观看到热点，可以打开 TiDB Dashboard 的 Key Visualizer：

```bash
tiup dashboard
```

在 Key Visualizer 中分别对 t_auto_inc 和 t_auto_random 执行批量 INSERT，你可以看到：
- t_auto_inc：一个明亮的矩形持续闪动（单点热点）
- t_auto_random：多个亮度较低的区域，均匀分布（写入分散）
:::
