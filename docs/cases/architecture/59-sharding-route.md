# 分库分表路由策略

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['分库分表', '路由', 'Sharding', 'UNION ALL', '水平拆分']" />

## 订单量突破亿级后，单表无法承载，按
订单量突破亿级后，单表无法承载，按 `user_id` 水平拆分为 4 个分片。但应用层忘记做路由计算，每个查询都"广播"到所有分片，4 个分片全扫一遍。分片数从 4 扩到 8 后，查询耗时反而翻倍。

```sql
-- 不知道数据在哪个分片，UNION ALL 扫描所有分片
SELECT * FROM t_order_0 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_1 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_2 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_3 WHERE user_id = 100;
```

::: warning 真实场景
分库分表后不做路由计算是常见的架构陷阱。短期内分片少时性能可接受，随着分片数增加，"广播查询"的代价线性增长。正确的做法是在应用层通过路由规则精确命中目标分片。
:::

## 问题分析

### bad.sql

```sql
-- 应用层没有做路由计算，只能"广播"查询到所有分片
SELECT * FROM t_order_0 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_1 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_2 WHERE user_id = 100
UNION ALL
SELECT * FROM t_order_3 WHERE user_id = 100;
```

### EXPLAIN 结果

```
+----+-------------+-----------+------+-------------+-------------+---------+-------+------+-------+
| id | select_type | table     | type | key         | key_len     | rows    |filtered| Extra |
+----+-------------+-----------+------+-------------+-------------+---------+-------+-------+
|  1 | PRIMARY     | t_order_0 | ref  | idx_user_id | 8           |      12 | 100.00| NULL  |
|  2 | UNION       | t_order_1 | ref  | idx_user_id | 8           |      10 | 100.00| NULL  |
|  3 | UNION       | t_order_2 | ref  | idx_user_id | 8           |      11 | 100.00| NULL  |
|  4 | UNION       | t_order_3 | ref  | idx_user_id | 8           |       9 | 100.00| NULL  |
+----+-------------+-----------+------+-------------+-------------+---------+-------+-------+
```

### 为什么慢

单看每个分片的 EXPLAIN，每个都走了 `idx_user_id` 索引。真正的代价在**架构层面**：

1. **4 倍网络开销**：应用向 4 个分片（可能分布在不同实例）发送 4 次查询
2. **3 个分片做无用功**：`user_id=100` 的数据只在 `t_order_0`，其余 3 个分片完全浪费
3. **连接占用**：4 个分片连接被占用，并发能力下降
4. **结果合并**：UNION ALL 需要在应用层或数据库层合并结果，增加 CPU 开销
5. **随分片数线性恶化**：8 个分片扫 8 次，64 个分片扫 64 次

## 优化方案

### good.sql

```sql
-- 应用层先做路由计算，精确查询目标分片
-- 路由规则: shard = user_id % 4
-- user_id = 100 -> 100 % 4 = 0 -> 目标分片是 t_order_0
SELECT * FROM t_order_0 WHERE user_id = 100;
```

### 原理

路由计算将"广播查询"变为"精确查询"：

1. **应用层路由**：`shard = user_id % 4`，user_id=100 → shard=0 → 直接查 `t_order_0`
2. **单次查询**：只访问 1 个分片，1 次网络 RTT
3. **与分片数无关**：无论 4 个分片还是 64 个分片，单次查询只访问 1 个分片
4. **性能等价单表**：查询性能与单表查询完全一致

### 对比

| | bad.sql（全分片扫描） | good.sql（精确路由） |
|---|---|---|
| 查询分片数 | 4 个 | 1 个 |
| 网络 RTT | 4 次 | 1 次 |
| 无效扫描 | 3 个分片 | 0 个 |
| 结果合并 | 需要 UNION ALL | 无需合并 |
| 随分片数增长 | 线性恶化 | 不受影响 |

<ExplainCompare
  :bad="{ type: '4×ref', key: 'idx_user_id × 4', rows: '42 (4分片合计)', Extra: 'UNION ALL 合并 4 个分片结果' }"
  :good="{ type: 'ref', key: 'idx_user_id', rows: '12', Extra: '精确路由到单分片，无需合并' }"
  improvement="查询分片数从 4 降到 1，网络开销减少 75%，性能与分片数无关"
/>

## 避坑指南

::: warning 注意事项

1. **路由规则要无状态**。`user_id % 4` 是无状态的，扩容时需要数据迁移。一致性哈希可减少迁移量。

2. **跨分片查询无法避免**。按 `user_id` 分片后，按 `order_no` 查询无法路由，需要维护映射表或全局索引。

3. **分片键选择至关重要**。选择查询频率最高的字段作为分片键（如 `user_id`），最大化精确路由的覆盖率。

4. **分布式事务是另一个坑**。跨分片的写入需要分布式事务（XA 或 TCC），性能和复杂度都会增加。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 分片路由 | 应用层实现 | 应用层实现（MySQL 原生不支持分片） |
| 并行查询 | ❌ 不支持 | ✅ 8.0.14+ 支持并行读取，可加速全分片扫描 |
| 分区表增强 | 基础分区 | ✅ 8.0 增强了原生分区功能，部分场景可替代分库分表 |

::: tip MySQL 原生分区 vs 分库分表
如果只是单机性能瓶颈，优先考虑 MySQL 原生 PARTITION（见 [案例 45](../ddl/45-partition-range)）。只有单机无法承载时才需要分库分表。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 59-sharding-route

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 59-sharding-route --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 59-sharding-route --no-seed
```
