# 游标分页替代深分页

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['分页', '游标分页', 'Keyset Pagination', '深分页']" />

## 场景痛点

资讯流、朋友圈、消息列表等场景中，用户持续向下翻页（"下一页"），数据量达到百万级后，翻到深页越来越慢。

```sql
-- 翻到第 5 万页（每页 20 条），OFFSET = 50000 × 20 = 1,000,000
SELECT * FROM t_feed
WHERE status = 1
ORDER BY created_at DESC, id DESC
LIMIT 1000000, 20;
```

案例 01 演示了用**延迟关联 + 覆盖索引**缓解深分页。但如果业务只需要"上一页/下一页"而不需要跳页，**游标分页**（Keyset Pagination）是更彻底的方案——无论翻到第几页，性能恒定。

::: warning 真实场景
朋友圈、微博、消息列表等无限滚动场景天然适合游标分页。用户从不需要"跳转到第 8723 页"，只需要不断"加载更多"。LIMIT OFFSET 在这些场景纯属浪费。
:::

## 问题分析

### bad.sql

```sql
SELECT id, user_id, content, status, created_at
FROM t_feed
WHERE status = 1
ORDER BY created_at DESC, id DESC
LIMIT 1000000, 20;
```

### EXPLAIN 结果

```
+----+-------------+--------+------+----------------------+---------+-------+--------+----------+---------------------+
| id | table       | type   | key                  | key_len | ref   | rows  | filtered| Extra               |
+----+-------------+--------+----------------------+---------+-------+--------+----------+---------------------+
|  1 | t_feed      | ref    | idx_status_created_id| 1       | const | 666K  | 100.00  | Backward index scan |
+----+-------------+--------+----------------------+---------+-------+--------+----------+---------------------+
```

### 为什么慢

关键在于 **LIMIT 1000000, 20** 的工作方式：

```
MySQL 执行流程:
1. 通过 idx_status_created_id 逆向扫描找到所有 status=1 的行  -> 66 万行
2. 逐行回表读取完整数据
3. 跳过前 1,000,000 行（← 每行都付出了回表代价）
4. 返回第 1,000,001 ~ 1,000,020 行
```

**被丢弃的 100 万行也要回表**。而且页数越深，OFFSET 越大，性能**线性退化**——第 10 万页比第 5 万页慢一倍。

::: tip 核心认知
`LIMIT N, M` 的代价不是 M，而是 **N + M**。OFFSET 本质上是在"数行"，数 100 万行和数 10 行的开销天差地别。
:::

## 优化方案

### good.sql

```sql
-- 游标分页：用上一页最后一条记录的 (created_at, id) 作为游标
-- 游标值：created_at = '2026-06-15 10:30:00', id = 123456
SELECT id, user_id, content, status, created_at
FROM t_feed
WHERE status = 1
  AND (created_at < '2026-06-15 10:30:00'
       OR (created_at = '2026-06-15 10:30:00' AND id < 123456))
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

### 原理

把 **OFFSET 跳行** 替换为 **WHERE 范围定位**：

```
bad:  LIMIT 1000000, 20
      -> 从头扫描 1,000,020 行，丢弃 100 万行

good: WHERE (created_at, id) < (游标值, 游标id)
      -> 索引直接定位到游标位置
      -> 从游标位置开始扫描 20 行就停止
```

**复合游标的必要性**：如果只用 `created_at` 做游标，当多条记录的 `created_at` 相同时，翻页会漏数据或重复数据。加上 `id` 作为第二排序键，形成 `(created_at, id)` 复合游标，保证每条记录的游标值唯一。

```
WHERE 条件等价于:
  (created_at, id) < ('2026-06-15 10:30:00', 123456)
  
展开为:
  created_at < '2026-06-15 10:30:00'
  OR (created_at = '2026-06-15 10:30:00' AND id < 123456)
```

索引 `idx_status_created_id (status, created_at, id)` 完美匹配这个 WHERE 条件，`type=range` 直接定位。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 扫描行数 | ~1,000,020 | **20** |
| 回表次数 | ~1,000,020 | **20** |
| 性能随页深度 | 线性退化 | **恒定** |
| 耗时 | ~520 ms | **~2 ms** |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_status_created_id', rows: '666,432', Extra: 'Backward index scan' }"
  :good="{ type: 'range', key: 'idx_status_created_id', rows: '20', Extra: 'Using index condition' }"
  improvement="扫描行数从 100 万降至 20，且无论翻到第几页都恒定，耗时下降 99.6%"
/>

## 避坑指南

::: warning 注意事项

1. **复合游标必须有 tiebreaker**。如果排序字段有重复值（如多行 `created_at` 相同），必须加上 `id` 作为第二排序键，否则会漏数据或重复数据。这是游标分页最常见的 bug。

2. **只适合"上一页/下一页"**。游标分页不支持跳页（"跳转到第 50 页"）。如果业务确实需要跳页，只能用 LIMIT OFFSET + 延迟关联方案（见 [案例 01](./01-deep-pagination)）。很多产品可以改为"加载更多"交互来规避跳页需求。

3. **游标方向决定排序**。向下翻用 `<`，向上翻用 `>` 且需反转 ORDER BY 方向。前端需记录当前页的游标和翻页方向。

4. **索引必须覆盖游标字段**。本例索引 `(status, created_at, id)` 完全匹配 `WHERE status=1 AND (created_at, id) < 游标`。如果索引只到 `created_at`，`id` 的范围条件无法走索引，会退化为扫描后过滤。

5. **数据变动会影响游标**。如果翻页过程中有新数据插入（`created_at` 大于当前游标），向下翻页不受影响（新数据在顶部）。但如果中间有数据删除，可能导致跳过或重复，前端需做去重处理。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 游标分页方案 | ✅ 有效 | ✅ 有效 |
| 降序索引 `DESC` | ❌ 解析但忽略，仍 filesort | ✅ 真正支持，可消除 filesort |
| 索引条件下推 ICP | ✅ 支持 | ✅ 支持 |
| Backward index scan | ❌ 不支持 | ✅ 逆向扫描免排序 |

::: tip 8.0 额外优化
8.0 可创建降序索引 `(status, created_at DESC, id DESC)`，完全匹配 `ORDER BY created_at DESC, id DESC` 的排序方向，消除逆向扫描的开销。5.7 虽然也能用游标分页，但需要额外的 filesort 步骤。
:::

## 对比案例 01（延迟关联）

| | 案例 01：延迟关联 | 案例 71：游标分页 |
|---|---|---|
| 适用场景 | 需要跳页 | 只需上一页/下一页 |
| 性能 | 深页仍需扫描索引 | 恒定 O(LIMIT) |
| 实现复杂度 | 低（SQL 改写） | 中（前端需管理游标） |
| 数据一致性 | 不受数据变动影响 | 插入/删除可能影响 |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 17-cursor-pagination

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 17-cursor-pagination --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 17-cursor-pagination --no-seed
```
