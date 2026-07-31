# TiDB Join 算法选择——Index Join、Hash Join、Merge Join、Index Hash Join、Index Merge Join

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['Join', 'Hash Join', 'Index Join', 'Merge Join', 'Broadcast Join', 'IndexLookUpJoin', 'Index Hash Join', 'Index Merge Join']" />

## 场景痛点

一个从 MySQL 迁移到 TiDB 的报表系统，某个核心 JOIN 查询突然从 200ms 飙升到 5s。DBA 检查 EXPLAIN 后发现 TiDB 选择了 Hash Join，而同样的 SQL 在 MySQL 中走的是 Index Nested Loop Join。

```sql
-- 报表查询：关联订单表和用户维度表
SELECT o.order_id, o.amount, u.user_name, u.city
FROM t_orders o JOIN t_users u ON o.user_id = u.user_id
WHERE o.create_time >= '2025-01-01';
```

在 MySQL 中，`t_users.user_id` 有主键索引，JOIN 走 Index Nested Loop，每次外表 `t_orders` 获取一行就用 `user_id` 去 `t_users` 精确查找。迁移到 TiDB 后，优化器统计信息显示 `t_users` 行数很大，选择了 Hash Join——对 `t_users` 全表扫描构建哈希表。但实际上 `user_id` 是主键，每次 Index Join 的查找开销极小，Hash Join 反而造成了不必要的全表扫描。

::: warning 真实场景

TiDB 的 EXPLAIN 通过算子树直观呈现使用了哪种 Join 算法，但识别各算法的算子特征需要系统学习。与 MySQL 不同，TiDB 不支持 `EXPLAIN FORMAT=JSON` 那种扁平输出——你必须会读 TiDB 的算子树，才能知道哪一步出了偏差。

:::

## 问题分析

本案例创建三张表：

- `t_join_a`（10 万行，`a_val` 1-10000，有 `idx_val` 索引）：模拟中等规模事实表
- `t_join_b`（5 万行，`b_val` 1-50000，有 `idx_val` 索引）：模拟另一张事实表
- `t_join_c`（500 行，`c_val` 1-500，**无 `c_val` 索引**）：模拟小型维表（缺少索引）

### TiDB 的五种 Join 算法

TiDB 支持以下 Join 算法，优化器根据表大小、索引可用性、等值/非等值条件自动选择：

| 算法 | EXPLAIN 根算子 | 核心原理 | 最佳场景 |
|------|---------------|---------|---------|
| **Hash Join** | `HashJoin_` | Build 侧构建哈希表，Probe 侧逐行探测 | 无索引、两表都大、非等值连接 |
| **Index Join (INLJ)** | `IndexJoin_` | 外表每行去内表索引做一次查找 | 外表较小、内表有高选择性索引 |
| **Merge Join** | `MergeJoin_` | 两表按连接列排序后合并游标 | 两表已排序或可用有序索引 |
| **Index Hash Join** | `IndexHashJoin_` | 外表构建哈希 + 内表索引查找 | 外表大、内表有索引（折中方案） |
| **Index Merge Join** | `IndexMergeJoin_` | 利用索引有序性合并 | 两表索引都覆盖连接列且有序 |

### TiDB Join 算法选型决策树

```
连接条件类型？
│
├── 非等值连接（>, <, BETWEEN, LIKE...）
│   └── Hash Join 或 Merge Join（INDEX JOIN 不可用）
│       决策: 看表是否已排序 → Merge Join
│             否则 → Hash Join
│
└── 等值连接（=）
    │
    ├── 被驱动表连接列是否有索引？
    │   │
    │   ├── 无索引 → Hash Join（唯一选择）
    │   │   └── 例外: 若被驱动表很小（< 几百行）→ 可考虑 Broadcast Hash Join
    │   │
    │   └── 有索引 → 进入索引可用分支
    │       │
    │       ├── 内表很小（< 几千行）且索引选择性高
    │       │   └── Index Join (INLJ) -- 最优点查路径
    │       │
    │       ├── 外表大 + 内表大 + 都有索引
    │       │   ├── Index Hash Join -- 哈希 + 索引混合
    │       │   └── Index Merge Join -- 两表索引有序时可合并
    │       │
    │       └── 两表索引均有序（keep order:true）
    │           └── Merge Join -- 线性合并 O(n+m)
    │
    └── 表大小对比悬殊？
        ├── 小表 vs 大表无索引 → Hash Join（小表 Build + 广播）
        └── 两表都大无索引 → Hash Join（必须）
```

### bad.sql（3 个非最优 Join 场景）

```sql
-- 场景1: 两表连接，被驱动表连接列无索引 → Hash Join 全量扫描
EXPLAIN SELECT a.a_name, a.a_val, c.c_name, c.c_val
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景2: 大表 JOIN 大表，优化器可能选 Hash Join 而非索引路径
EXPLAIN SELECT a.a_name, b.b_name, a.a_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- 场景3: 非等值连接只能走 Hash Join
EXPLAIN SELECT a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val > b.b_val;
```

### EXPLAIN 结果

**场景1**：Hash Join（被驱动表 `t_join_c.c_val` 无索引）

```
HashJoin_11                    | root | inner join, equal:[eq(test.t_join_a.a_val, test.t_join_c.c_val)]
├─HashJoinBuild_13(Build)      | root |
│ └─TableReader_17 → TableFullScan_16 | cop[tikv] | table:t_join_c
└─HashJoinProbe_12(Probe)      | root |
  └─TableReader_15 → TableFullScan_14    | cop[tikv] | table:t_join_a
```

根算子 `HashJoin_11`，Build 侧全扫 `t_join_c`（500 行），Probe 侧全扫 `t_join_a`（10 万行）。`t_join_c.c_val` 无索引导致无法走 Index Join。

**场景2**：两大表 Join，`t_join_a` 和 `t_join_b` 都全表扫描

```
HashJoin_10                    | root | inner join, equal:[eq(...)]
├─HashJoinBuild_12(Build) → TableFullScan_15(t_join_b) | 全扫 5 万行
└─HashJoinProbe_11(Probe) → TableFullScan_13(t_join_a) | 全扫 10 万行
```

即使两表都有 `idx_val` 索引，优化器可能因统计信息偏差选择 Hash Join 而非 Index Join。

**场景3**：非等值连接 `>` 只能 Hash Join

```
HashJoin_10 | root | inner join, other cond:gt(...)
```

`operator info` 中为 `other cond:gt(…)` 而非 `equal:[eq(…)]`，明确标注为非等值连接。

### 为什么错误的 Join 算法会慢

以场景1为例，Hash Join 的执行流程：

```
Build 阶段:
  TableFullScan(t_join_c) → 扫描 500 行 → 构建哈希表(key=c_val)
  开销: O(500)，可接受

Probe 阶段:
  TableFullScan(t_join_a) → 扫描 10 万行 → 逐行探测哈希表
  开销: O(100000)，主要瓶颈
```

如果 `t_join_c.c_val` 有索引且走 Index Join：

```
Build 阶段:
  TableFullScan(t_join_a) → 扫描 10 万行 → 逐行获取 a_val

Probe 阶段:
  对每行 a_val 值 → IndexRangeScan(t_join_c, idx_val) → 精确查找
  ⚠️ TiDB 分布式关键: 每次 IndexRangeScan 都是一次 TiDB → TiKV 的 RPC 调用
  每次 RPC: ~0.5-1ms（含网络+TiKV coprocessor 调度）
  总开销: 100,000 × 0.5ms ≈ 50 秒（远大于 Hash Join 的 ~100ms）

  CPU 维度看: 100,000 × log₂(500) ≈ 90 万次比较，理论很快
  但 TiDB 分布式维度: 10 万次 RPC 是真正瓶颈，Hash Join 远优
```

::: tip 核心认知

TiDB EXPLAIN 中 Join 算子的选择取决于三个因素：**统计信息准确性 + 索引可用性 + 表大小估算**。看到 `HashJoin` 根算子时，检查 Build/Probe 两侧是否有可用但未被使用的索引 -- 如果有，说明优化器决策可能有问题（通常是因为统计信息不准）。

:::

## 优化方案

### good.sql

```sql
-- 场景1: 给小表加索引 → Index Join (INLJ)
ALTER TABLE t_join_c ADD KEY idx_val (c_val);
EXPLAIN SELECT a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景2: 等值连接 + 索引 → 优化器自动选择 Index Hash Join
EXPLAIN SELECT a.a_name, b.b_name, a.a_val, b.b_val
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- 场景3: 显式指定 Join 算法 Hint
-- Hash Join Hint
EXPLAIN SELECT /*+ HASH_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val;

-- Merge Join Hint
EXPLAIN SELECT /*+ MERGE_JOIN(a, b) */ a.a_name, b.b_name
FROM t_join_a a JOIN t_join_b b ON a.a_val = b.b_val WHERE a.a_val < 100;

-- Index Join Hint
EXPLAIN SELECT /*+ INL_JOIN(c) */ a.a_name, a.a_val, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;

-- 场景4: Broadcast Join 控制
SHOW VARIABLES LIKE 'tidb_prefer_broadcast_join';
SET SESSION tidb_prefer_broadcast_join = ON;
EXPLAIN SELECT a.a_name, c.c_name
FROM t_join_a a JOIN t_join_c c ON a.a_val = c.c_val;
SET SESSION tidb_prefer_broadcast_join = DEFAULT;
```

### EXPLAIN 优化后结果

**加索引后走 Index Join**：

```
IndexJoin_11                         | root | inner join, inner:IndexReader_10
├─TableReader_14(Build) → TableFullScan_13(t_join_a) | 全扫 10 万行（外表/驱动表）
└─IndexReader_10(Probe) → IndexRangeScan_9(t_join_c, idx_val) | 索引查找内表
```

对比 bad.sql 场景1：`HashJoin → IndexJoin`，`TableFullScan(t_join_c) → IndexRangeScan(t_join_c, idx_val)`，被驱动表从全表扫描变为索引查找。

**Index Hash Join**（两大表等值连接 + 索引）：

```
IndexHashJoin_11                     | root | inner join, inner:IndexReader_10
├─TableReader_14(Build) → TableFullScan_13(t_join_a) | 外表构建哈希表
└─IndexReader_10(Probe) → IndexRangeScan_9(t_join_b, idx_val) | 内表索引扫描 + 哈希探测
```

**Merge Join**（Hint 强制）：

```
MergeJoin_12                         | root | left key:…a_val, right key:…b_val
├─IndexReader_17(Build) → IndexRangeScan_16(t_join_a, idx_val) | keep order:true
└─IndexReader_19(Probe) → IndexFullScan_18(t_join_b, idx_val)   | keep order:true
```

### 原理

**Index Join (INLJ) 原理**：

```
外表(驱动表) t_join_a:
  FOR EACH row in t_join_a:
    key = row.a_val
    -- 在内表索引中查找匹配行
    result = IndexLookup(t_join_c.idx_val, key)
    -- 输出连接结果
    OUTPUT row JOIN result
```

外表每行触发一次内表的索引查找。外表 10 万行 → 10 万次索引查找，但每次查找成本极低（B+Tree 高度 2-3 层）。关键是**被驱动表必须有可用索引**。

**Hash Join 原理**：

```
Build 阶段:
  读取 t_join_c（500 行），对每行计算 hash(c_val)，存入哈希表
  哈希表大小: 500 条目，内存友好

Probe 阶段:
  读取 t_join_a（10 万行），对每行计算 hash(a_val)，探测哈希表
  命中则输出连接结果
```

Hash Join 的优势是 Probe 侧一次扫描（不需要反复随机 I/O），代价是 Build 侧需要足够内存存储哈希表。

**Index Hash Join 原理**：

```
Build 阶段:
  读取 t_join_a（外表），对每行计算 hash(a_val)，存入哈希表

Probe 阶段:
  通过 t_join_b 的 idx_val 索引进行范围扫描
  对扫描得到的每行，用 hash(b_val) 探测哈希表
  命中则输出连接结果
```

Index Hash Join 是 Hash Join 和 Index Join 的混合：用索引避免全表扫描被驱动表，同时用哈希表避免大量索引随机查找。

### 五种 Join 算法对照

| 算法 | 被驱动表访问方式 | 外表扫描次数 | 内存需求 | 适用数据量 | Hint |
|------|-----------------|-------------|---------|-----------|------|
| **Index Join (INLJ)** | 索引逐行查找 | 1次 | 极小 | 外表 < 1万行 | `INL_JOIN()` |
| **Hash Join** | 全表扫描后哈希探测 | 1次 | Build 侧哈希表内存 | 不限（小表 Build） | `HASH_JOIN()` |
| **Merge Join** | 排序后游标合并 | 1次 | 排序缓存 | 两表都大 + 有序 | `MERGE_JOIN()` |
| **Index Hash Join** | 索引扫描 + 哈希探测 | 1次 | Build 侧哈希表内存 | 外表大 + 内表有索引 | `INL_HASH_JOIN()` |
| **Index Merge Join** | 索引有序合并 | 1次 | 极小 | 两表索引有序 | `INL_MERGE_JOIN()` |

## 深入原理

### TiDB Join 算子的 task 分布

TiDB 的 Join 算子与 MySQL 在架构上有本质区别——涉及分布式任务调度：

```
┌──────────────────────────────────────────────────────────────────┐
│  TiDB SQL Layer (root task)                                       │
│                                                                    │
│  HashJoin_xx (root)                                               │
│  ├─ HashJoinBuild_xx (root)  ← 协调 Build，读取各 TiKV 数据        │
│  │   └─ TableReader_xx (root) ← 从各 TiKV 拉取数据                │
│  │       └─ TableFullScan_xx (cop[tikv]) ← 实际扫描在 TiKV 执行    │
│  └─ HashJoinProbe_xx (root)  ← 协调 Probe                         │
│      └─ TableReader_xx (root)                                     │
│          └─ TableFullScan_xx (cop[tikv])                          │
│                                                                    │
│  ⚠ 所有 Join 算法的 Build/Probe 都在 TiDB 节点内存中完成             │
│  数据从 TiKV cop[tikv] 拉到 TiDB root 后，Join 在 TiDB 层执行       │
└──────────────────────────────────────────────────────────────────┘
```

**关键区别**：TiDB 的 Join 在 SQL 层（root task）执行，数据从各 TiKV 节点拉取到 TiDB 节点后进行关联。这意味着 Join 受限于 TiDB 节点的内存和网络带宽。

### Index Join vs Index Hash Join 的执行差异

```
Index Join (INLJ):
  t_join_a (10万行)                t_join_c (500行, idx_val)
  ┌─────────────────┐             ┌──────────────────────┐
  │ Row1: a_val=500 │──index──►  │ lookup c_val=500      │
  │ Row2: a_val=32  │──index──►  │ lookup c_val=32       │
  │ Row3: a_val=7800│──index──►  │ lookup c_val=7800     │
  │ ...             │             │ ...                   │
  └─────────────────┘             └──────────────────────┘
  每次外表行 → 一次内表索引查找（随机 I/O 模式）

Index Hash Join:
  t_join_a (10万行)                t_join_b (5万行, idx_val)
  ┌─────────────────┐  hash表    ┌──────────────────────┐
  │ Row1: a_val=500 │──►[500]   │ idx_val 范围扫描       │
  │ Row2: a_val=32  │──►[32]    │ b_val=1 → hash(1)→❌   │
  │ Row3: a_val=7800│──►[7800]  │ b_val=32 → hash(32)→✅ │
  │ ...             │  [ ... ]  │ b_val=500→ hash(500)→✅│
  └─────────────────┘           │ ...                   │
  先构建哈希表，再内表索引扫描   └──────────────────────┘
```

**Index Hash Join 的优势**：当内表索引范围很大时（如外表 10 万行覆盖 1-10000，内表 5 万行覆盖 1-50000），Index Join 需要 10 万次随机索引查找；而 Index Hash Join 只需对内表做一次有序索引范围扫描 + 哈希探测，大幅减少随机 I/O。

### MySQL Join 算法 vs TiDB Join 算法对比

| 概念 | MySQL 8.0 | TiDB |
|------|----------|------|
| Hash Join | MySQL 8.0 引入，`Extra: Using join buffer (hash join)` | `HashJoin_` 算子 + Build/Probe 子树 |
| Nested Loop Join | `Extra: Using index` 或 `type: ref` | `IndexJoin_` 算子 + `IndexRangeScan` |
| Block Nested Loop | 5.7 默认无索引 JOIN 算法 | TiDB 无此算法（用 Hash Join 替代） |
| Merge Join | MySQL 不支持（需手动排序后模拟） | `MergeJoin_` 算子 + 有序索引扫描 |
| Broadcast Join | 不适用（单机架构） | `tidb_prefer_broadcast_join` 控制 |
| Join 执行位置 | 单机内存 | TiDB SQL 层（root task），数据从 TiKV 拉取 |
| 分布式考量 | 无 | 跨节点数据传输、内存占用、Broadcast vs Shuffle |

### TiDB Join 性能调优清单

1. **检查 `ANALYZE TABLE` 统计信息**：`SHOW STATS_HEALTHY` 查看统计健康度，低于 80% 需重新收集
2. **检查索引可用性**：被驱动表连接列是否有索引？索引覆盖度如何？用 `SHOW INDEX FROM` 查看
3. **查看 EXPLAIN ANALYZE 实际耗时**：关注 `exec info` 中的 `time` 和 `rows`，验证 `estRows` 与实际 `actRows` 的偏差
4. **使用 Join Hint 干预**：如果确认优化器选错，用 `/*+ HASH_JOIN() */` / `/*+ INL_JOIN() */` 等 Hint 强制指定
5. **调整 Broadcast Join**：小表 JOIN 大表时，`tidb_prefer_broadcast_join=ON` 可将小表广播到各 TiKV 节点本地 Join
6. **考虑分桶策略**：对于超大表 JOIN，通过分桶（如相同分区键）使数据共置，减少跨节点数据传输

## 本地复现

```bash
# 启动 TiDB 环境并执行案例
./scripts/run-case.sh 91-tidb-join-algorithms --ver tidb
```

执行后观察：
- bad.sql 中各场景的 EXPLAIN 算子树，重点关注根算子的类型（`HashJoin_` / `IndexJoin_` / `MergeJoin_`）
- good.sql 加索引后，根算子从 `HashJoin` 变为 `IndexJoin`
- 各种 Hint 对 Join 算法的精确控制效果
- `operator info` 列中 `equal:` vs `other cond:` 对算法选择的影响
- `SHOW VARIABLES LIKE 'tidb_prefer_broadcast_join'` 和广播行为

::: tip 如何判断 Join 算法是否合理

1. **看到 `HashJoin`** + 被驱动表连接列有索引 → 检查统计信息是否准确，尝试加 `/*+ INL_JOIN() */` Hint 对比 EXPLAIN
2. **看到 `IndexJoin`** + 外表 estRows 很大（> 10 万）→ 考虑是否改为 Index Hash Join（减少随机索引查找次数）
3. **看到 `MergeJoin`** + `keep order:true` + 无可用有序索引 → 注意额外的 Sort 开销
4. **看到非等值连接** → 只能 Hash Join 或 Merge Join，确保 Build 侧选择较小的表
5. **两表数据量悬殊**（如 10 万 vs 500）→ 使用 Broadcast Join 将小表广播，避免 Shuffle

:::

## 常见问题

**Q: TiDB 的 Index Join 与 MySQL 的 Index Nested Loop Join 是一回事吗？**

A: 原理相同，都是外表每行去内表做索引查找。区别在于 TiDB 中内表可能分布在多个 TiKV 节点，每次索引查找可能涉及跨节点 RPC 调用。TiDB 会做批量优化（Batch Index Lookup），将多个外表键值打包成一次请求。

**Q: 为什么有两张表都有索引但 EXPLAIN 显示走 Hash Join？**

A: 常见原因：(1) 统计信息不准，优化器误判全表扫描 + Hash Join 比索引查找更优；(2) 被驱动表 estRows 太大，优化器认为大量索引随机查找不如一次全扫；(3) 两张表都是大表时 Index Join 的 10 万次随机 I/O 确实可能不如 Hash Join。解决：更新统计信息（`ANALYZE TABLE`）或使用 Hint 强制指定。

**Q: `tidb_prefer_broadcast_join` 什么时候应该开启？**

A: 当小表数据量很小（< 几十 MB）且大表很大的场景。开启后 TiDB 会将小表完整数据广播到每个存有大表数据的 TiKV 节点，在各节点本地完成 Join 后汇总，避免 Shuffle 阶段的数据传输。但如果小表也很大，广播反而会放大网络开销。

**Q: Index Hash Join 和 Index Join 有什么区别？**

A: Index Join（INLJ）是外表每行去内表做一次索引查找，适合外表行数较少的情况。Index Hash Join 是先对外表构建哈希表，然后内表按索引扫描后用哈希表探测，适合外表较大而内表也有索引的场景。选择依据：外表行数多 → Index Hash Join；外表行数少 → Index Join。

**Q: TiDB 的 Join 为什么都在 root task 执行？能不能下推到 TiKV？**

A: TiDB 当前版本的 Hash Join / Merge Join 在 SQL 层（root task）执行，因为需要在同一节点维护哈希表或排序状态。TiFlash MPP 模式下可将部分 Join 下推到 TiFlash 节点执行。Coprocessor 下推主要适用于扫描、过滤、聚合等单表操作，跨表 Join 暂不支持在 TiKV Coprocessor 中执行。
