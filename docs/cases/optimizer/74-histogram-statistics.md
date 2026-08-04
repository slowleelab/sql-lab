# 直方图统计优化选错索引

<CaseMeta difficulty="⭐⭐⭐" category="优化器与8.0新特性" versions="8.0" :tags="['直方图', '统计信息', '优化器选错索引', '8.0新特性']" />

## 20 万变慢
任务表 `t_task` 有 20 万条记录，`status` 列仅 3 个取值（0 待处理、1 处理中、2 已完成），但分布极度不均--**99% 的数据都是 status=0**。某天业务反馈查询某个用户的待处理任务突然变慢，SQL 本身很简单，索引也建了，但 EXPLAIN 一看，优化器选了 `idx_status` 而不是更高效的 `idx_user_created`。

```sql
-- 查某用户的待处理任务
SELECT id, user_id, status, created_at
FROM t_task
WHERE status = 0
  AND user_id = 12345;
```

表上建了两个索引：`idx_status (status)` 和 `idx_user_created (user_id, created_at)`。直觉上 `user_id = 12345` 的选择性远好于 `status = 0`（前者约 100 行，后者约 19.8 万行），优化器应该选 `idx_user_created`。但实际却选了 `idx_status`，导致 19.8 万次无效回表，查询耗时从几毫秒飙到 **380ms**。

::: warning 真实场景
这是数据倾斜场景下最常见的坑。`status`、`is_deleted`、`type` 这类枚举列在生产中往往分布极度不均（如 99% 的记录 is_deleted=0）。当查询同时涉及高倾斜列和选择性更好的列时，优化器因缺乏列值分布信息，会按"均匀分布"假设低估高倾斜列的匹配行数，从而误选索引。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 无直方图时，优化器认为 status=0 选择性好（基数低），可能选 idx_status
-- 但 status=0 实际占 99% 数据（约 19.8 万行），通过 idx_status 扫描后还要回表过滤 user_id
-- 选错索引导致大量无效回表
SELECT id, user_id, status, created_at
FROM t_task
WHERE status = 0
  AND user_id = 12345;
```

### EXPLAIN 结果

```
+----+-------------+--------+------+-----------------------------------+------------+---------+-------+--------+----------+-------------+
| id | select_type | table  | type | possible_keys                     | key        | key_len | ref   | rows   | filtered | Extra       |
+----+-------------+--------+------+-----------------------------------+------------+---------+-------+--------+----------+-------------+
|  1 | SIMPLE      | t_task | ref  | idx_status,idx_user_created       | idx_status | 1       | const |  66000 |   100.00 | Using where |
+----+-------------+--------+------+-----------------------------------+------------+---------+-------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 通过 idx_status 等值查找 |
| key | `idx_status` | **优化器选错了索引！** |
| possible_keys | `idx_status,idx_user_created` | 两个索引都可用 |
| rows | ~66,000 | 优化器以为 status=0 匹配约 6.6 万行（严重低估） |
| filtered | 100.00 | 优化器以为回表后 user_id 过滤无额外损耗 |
| Extra | `Using where` | 回表后还需用 user_id 过滤 |

### 为什么慢

无直方图时，优化器对 `status` 列只有"3 个不同值"的基数统计，按**均匀分布假设**估算每个值约 200000/3 ≈ 66000 行。

但实际 `status=0` 占 99% = **约 19.8 万行**，优化器严重低估了匹配行数。

```
MySQL 执行流程:
1. 通过 idx_status 二级索引定位到 status=0 的索引条目 -> 约 19.8 万条
2. 逐条回表到聚簇索引读取完整行
3. 回表后用 user_id = 12345 过滤（每个 user_id 仅约 100 行）
4. 最终仅保留约 99 行，却做了 19.8 万次回表
```

19.8 万次随机回表中，99.95% 是无效的（user_id 不匹配），是巨大的 I/O 浪费。

正确做法应选 `idx_user_created`：通过 user_id=12345 精确定位（约 100 行），再用 status 过滤，只需约 100 次回表。

::: warning 优化器的"均匀分布"假设
MySQL 优化器在缺乏直方图时，默认假设列值均匀分布。对于 status、is_deleted 这类枚举列，数据倾斜极为常见（如 status=0 待处理占 99%）。当查询同时涉及高倾斜列和选择性更好的列时，优化器会因低估高倾斜列的匹配行数而误选索引。
:::

::: tip 核心认知
优化器选错索引的根因不是索引设计问题，而是**统计信息缺失**--没有列值分布数据，优化器只能按均匀分布假设估算，从而误判选择性。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 创建直方图后，优化器知道 status=0 占 99%（选择性极差）
-- 从而选择 idx_user_created 通过 user_id 先精确定位（每个 user_id 约 100 行）
-- 同样查询，但需先执行 setup-good.sql 创建直方图
SELECT id, user_id, status, created_at
FROM t_task
WHERE status = 0
  AND user_id = 12345;
```

先执行 setup-good.sql 创建直方图：

```sql
-- setup-good.sql: 在 status 列创建直方图（8.0 专有特性）
-- 直方图精确记录列值分布，让优化器感知 status=0 占 99% 的数据倾斜
-- 注: 直方图仅 8.0 支持；创建后需确认优化器能据此选对索引
ANALYZE TABLE t_task UPDATE HISTOGRAM ON status WITH 100 BUCKETS;
```

### 原理

直方图让优化器知道 `status=0` 实际占 99%（19.8 万行），选择性极差。

优化器重新评估两个索引的代价：
- `idx_status`（status=0）：匹配 19.8 万行 -> 19.8 万次随机回表 -> 再过滤 user_id
- `idx_user_created`（user_id=12345）：匹配约 100 行 -> 100 次回表 -> 再过滤 status

有了直方图，优化器明白走 `idx_status` 要回表 19.8 万次（几乎全表），代价远高于走 `idx_user_created` 的 100 次回表。因此改选 `idx_user_created`。

```
执行过程:
1. 通过 idx_user_created 定位 user_id=12345 的索引条目 -> 约 100 条
2. 回表读取约 100 行完整数据
3. 用 status=0 过滤（保留约 99 行）
4. 仅约 100 次回表，99% 的 status 过滤在内存中完成
```

直方图不改变执行路径，而是让优化器**做对决策**。它是存储在 `information_schema.COLUMN_STATISTICS` 中的统计信息，仅在优化阶段读取，零运行时开销。

### 对比

| | bad.sql (无直方图) | good.sql (有直方图) |
|---|---|---|
| key | idx_status | **idx_user_created** |
| rows 预估 | ~66,000（严重低估） | ~100（准确） |
| 回表次数 | ~198,000 | **~100** |
| I/O 模式 | 随机 I/O（大量） | 随机 I/O（极少） |
| 耗时 | ~380 ms | **~2 ms** |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_status', rows: '66,000（实际198,000）', Extra: 'Using where' }"
  :good="{ type: 'ref', key: 'idx_user_created', rows: '100', Extra: 'Using where' }"
  improvement="回表次数从 19.8 万降到 100，耗时下降 190 倍"
/>

## 避坑指南

::: warning 注意事项

1. **直方图仅 8.0 支持**。`ANALYZE TABLE ... UPDATE HISTOGRAM ON` 是 8.0 专属特性，5.7 无此功能。5.7 中只能通过强制索引（FORCE INDEX）或修改索引设计来规避优化器选错索引的问题。

2. **直方图不会修改索引或数据**。它只是统计信息，存储在 `information_schema.COLUMN_STATISTICS`。数据变更后需要重新执行 `ANALYZE TABLE ... UPDATE HISTOGRAM` 刷新，否则分布信息会过时。

3. **不是所有列都需要直方图**。直方图对数据倾斜严重的列（如 status、is_deleted、type）效果显著；对主键、唯一键等均匀分布的列无意义。在选择性均匀的列上创建直方图只是浪费存储。

4. **直方图对不同值做不同决策**。对 `status=2`（仅占 0.5%）的查询，有直方图后优化器仍会选择 `idx_status` 索引（因为这时它确实选择性高）。直方图的价值是让优化器**对不同值做出不同最优决策**。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 直方图统计 | ❌ 不支持 | ✅ `ANALYZE TABLE ... UPDATE HISTOGRAM` |
| 列值分布感知 | ❌ 仅均匀分布假设 | ✅ 精确记录列值分布 |
| 优化器选错索引 | ❌ 只能靠 FORCE INDEX 规避 | ✅ 直方图帮助自动选对 |
| `information_schema.COLUMN_STATISTICS` | ❌ 无此表 | ✅ 存储直方图数据 |

::: tip 8.0 直方图
如果你的查询涉及数据倾斜列（status、is_deleted、type），在 8.0 中创建直方图：
```sql
ANALYZE TABLE t_task UPDATE HISTOGRAM ON status WITH 100 BUCKETS;
```
让优化器感知真实分布，自动选对索引。这是零运行时开销、纯统计层面的优化。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 74-histogram-statistics

# 跳过造数据重跑
./scripts/run-case.sh 74-histogram-statistics --no-seed
```
