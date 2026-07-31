# 自适应哈希索引 AHI 优化高频等值查询

<CaseMeta difficulty="⭐⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['AHI', 'innodb_adaptive_hash_index', '自适应哈希', '热数据', 'Buffer Pool']" />

## 场景痛点

某订单表的 `idx_user_id` 上有大量等值查询 `WHERE user_id = ?`，已经走 `ref` 索引，单次查询约 0.5ms。但**热点用户**（如大客户、热门商家）的查询每秒上万次，监控显示 Buffer Pool 命中率从 99% 降到 95%——B+ 树索引在 buffer pool 中虽然命中，但每次仍要走 3~4 层树高（~4 次随机读）。业务方希望进一步压到 0.1ms 以内。

```sql
-- 热点用户的高频等值查询
SELECT * FROM t_order WHERE user_id = 888888;
-- 单次 ~0.5ms（已走 idx_user_id），热点用户每秒 1 万次
```

::: warning 真实场景
电商大促期间，少数 VIP 用户的订单查询占比可能超过 30%。即使已经走二级索引，B+ 树的多次随机读 + 缓冲池 LRU 抖动仍可能导致 P99 延迟超标。**自适应哈希索引（AHI）** 是 InnoDB 在内存中为热点 page 建立的"二级索引的索引"，将 B+ 树查找从 O(log N) 降到 O(1)。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 在默认配置下，AHI 虽已开启但容量受限
-- 验证当前 AHI 状态
SHOW ENGINE INNODB STATUS\G  -- 查看 "INSERT BUFFER AND ADAPTIVE HASH INDEX" 段

-- 模拟热点用户的高频等值查询（1000 次相同 user_id）
SET @hot_user = 888888;
SELECT BENCHMARK(1000, (SELECT COUNT(*) FROM t_order WHERE user_id = @hot_user)) AS hit;
-- 单次 ~0.5ms × 1000 次 ≈ 500ms（含 B+ 树 3-4 次 page 寻道）
```

### EXPLAIN 结果

```
+----+-------------+--------+------+---------------+-------------+---------+-------+------+-------+
| id | select_type | table  | type | possible_keys | key         | key_len | ref   | rows | Extra |
+----+-------------+--------+------+---------------+-------------+---------+-------+------+-------+
|  1 | SIMPLE      | t_order| ref  | idx_user_id   | idx_user_id | 8       | const |    1 | NULL  |
+----+-------------+--------+------+---------------+-------------+---------+-------+------+-------+
```

`type=ref`、`rows=1`——单次查询已经最优。但**重复执行 1000 次**时，每次仍要 B+ 树定位 page。

### 为什么慢

InnoDB 的二级索引本质是 **B+ 树**：

| 操作 | 代价 | 说明 |
|------|------|------|
| 单次 B+ 树查找 | 3~4 次 page 寻道 | 每层 page 在 buffer pool 中 |
| buffer pool 未命中 | 1 次磁盘 IO | 约 10ms（机械）/ 0.1ms（NVMe） |
| 1000 次相同查询 | ~500ms | 4 次寻道 × 1000 次 + LRU 抖动 |

**热点 page 反复访问**意味着同一组 buffer pool page 被反复寻道，却不能进一步加速。**AHI 的作用**就是为这些热点 page 建立内存哈希表，下次直接 O(1) 定位。

## 优化方案

### good.sql

```sql
-- good.sql: 启用并调优自适应哈希索引
-- AHI 在 MySQL 5.7/8.0 默认开启（innodb_adaptive_hash_index=ON）
-- 但默认分区数可能不足，导致热点 page 哈希冲突

-- 1. 确认 AHI 已启用
SHOW VARIABLES LIKE 'innodb_adaptive_hash_index';
-- 应该为 ON

-- 2. 查看 AHI 状态（关键指标）
SHOW ENGINE INNODB STATUS\G
-- 关注: "Hash table size" / "Heap used" / "Hash searches/s" / "Non-hash searches/s"
-- 健康状态: hash searches 远大于 non-hash searches

-- 3. 调大 AHI 分区数（默认 8，高并发下建议 64-256）
SET GLOBAL innodb_adaptive_hash_index_parts = 128;

-- 4. 再次执行热点查询（已建立 AHI 后）
SELECT BENCHMARK(1000, (SELECT COUNT(*) FROM t_order WHERE user_id = @hot_user)) AS hit;
-- 单次 ~0.1ms × 1000 次 ≈ 100ms（4-5 倍加速）
```

### 原理

**自适应哈希索引（AHI）** 是 InnoDB 内部的**只读、内存级哈希索引**：

```
┌──────────────────────────────────────────┐
│           InnoDB Buffer Pool              │
│  ┌──────────────┐    ┌──────────────┐    │
│  │  B+ Tree     │    │  Hash Index  │    │
│  │  (二级索引)  │◀──▶│  (AHI)       │    │
│  │  page 1~N   │    │  热点 page   │    │
│  └──────────────┘    └──────────────┘    │
│         ▲                    ▲            │
│         │                    │            │
│    B+ 树查找 O(log N)   哈希查找 O(1)    │
└──────────────────────────────────────────┘
```

**关键特性**：

1. **自动建立**：当某个 page 的等值查询被访问 17 次以上（`innodb_adaptive_hash_index_searches` 触发），InnoDB 自动为该 page 建立哈希索引
2. **只读**：AHI 仅用于**查询**加速，不维护 INSERT/UPDATE/DELETE 时的同步
3. **分区结构**：默认 8 个分区（5.7），高并发热点下需调到 64-256 减少锁争用
4. **内存占用**：默认 `innodb_adaptive_hash_index` 占用 buffer pool 的 1/64，可通过 buffer pool size 间接调整

**AHI 适用场景**：

| 场景 | 适合 AHI | 不适合 |
|------|---------|--------|
| 等值查询 = | ✅ 最佳 | |
| IN 列表 | ✅ | |
| 范围查询 > < BETWEEN | ❌ 不建立 | |
| 频繁 UPDATE 的列 | ❌ 维护成本高 | |
| 唯一索引 | ❌ 已有索引足够快 | |

### 对比

| | bad (AHI 默认) | good (AHI 调优) |
|---|---|---|
| Hash table size | ~20MB | ~50-100MB（自动扩展） |
| 分区数 | 8 | 128 |
| 热点查询单次延迟 | 0.5ms | 0.1ms |
| hash searches / sec | 1 万 | 10 万+ |
| Non-hash searches | 1 万 | 0.5 万 |
| 锁争用 | 高 | 低（多分区分散） |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_user_id', rows: '1', Extra: 'B+ 树 3-4 层寻道 ~0.5ms' }"
  :good="{ type: 'AHI hash', key: 'idx_user_id', rows: '1', Extra: '哈希 O(1) 定位 ~0.1ms' }"
  improvement="热点等值查询 5 倍加速，P99 延迟从 0.5ms 降到 0.1ms"
/>

## 避坑指南

::: warning 注意事项

1. **AHI 不会自动监控是否有效**。可通过 `SHOW ENGINE INNODB STATUS` 中的 `Hash searches/s` vs `Non-hash searches/s` 比例判断效果。健康的 AHI 应该让 hash searches 远大于 non-hash。

2. **AHI 占用 buffer pool 内存**。默认占用 buffer pool 的 1/64（约 8MB / 512MB buffer pool）。`innodb_buffer_pool_size` 调整会影响 AHI 大小。如果业务更需要 data page 缓存，可临时关闭 AHI。

3. **写密集场景 AHI 收益小**。AHI 仅加速**读**路径，每次写操作需额外维护哈希。UPDATE/DELETE 多的表，AHI 维护成本可能超过查询收益。

4. **分区数调优**。`innodb_adaptive_hash_index_parts`（8.0 引入，5.7 默认 8 且只读）。高并发热点场景调到 64-256 可显著减少 AHI mutex 争用。需重启才能修改（8.0.13+ 部分版本可动态）。

5. **范围查询不会建立 AHI**。B+ 树的 `>`、`<`、`BETWEEN`、`LIKE 'abc%'` 等范围条件不会触发 AHI 建立。AHI 只对纯等值查询有效。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `innodb_adaptive_hash_index` 默认 | ON | ON |
| `innodb_adaptive_hash_index_parts` | 8（只读，需重启） | 默认 8（8.0.13+ 部分可动态调整到 256） |
| AHI 状态监控 | `SHOW ENGINE INNODB STATUS` | 同 5.7 + `INFORMATION_SCHEMA.INNODB_METRICS` |
| 对 DDL 影响 | AHI 在 DDL 时清空 | 同 5.7 |
| 与 temp table 交互 | 不影响 | 不影响 |

::: tip 推荐配置
- **8.0.13+**：`my.cnf` 中设置 `innodb_adaptive_hash_index_parts=64` 或 128
- **5.7**：保持默认 8 分区即可（除非监控到 AHI 锁争用）
- **写密集**：可临时关闭（`SET GLOBAL innodb_adaptive_hash_index=OFF`），但需在低峰期操作
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 103-adaptive-hash-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 103-adaptive-hash-index --ver 5.7
```
