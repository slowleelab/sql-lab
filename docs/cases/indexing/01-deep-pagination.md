# 深度分页 LIMIT 大偏移

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['分页', '延迟关联', '覆盖索引', '深分页']" />

## 翻到第 10 万页：50ms 飙升到 2 秒的深分页
电商后台的订单管理页面，客服人员需要翻看历史订单。前几页响应很快，但当翻到**第 10 万页**时，接口耗时从 50ms 飙升到 **2 秒以上**，甚至触发数据库慢查询告警。

```sql
-- 每页 20 条，第 10 万页的 OFFSET = 100000 × 20 = 2,000,000
SELECT * FROM t_order
WHERE status = 1
ORDER BY created_at DESC
LIMIT 2000000, 20;
```

这就是经典的 **"深分页"** 问题——LIMIT 的偏移量越大，性能越差。

::: warning 真实场景
这不是假设。任何支持翻页的后台管理系统（订单、日志、流水、消息记录），只要数据量超过百万，用户翻到深页时就会踩到这个坑。
:::

## 问题分析

### bad.sql

```sql
SELECT id, user_id, order_no, amount, status, created_at
FROM t_order
WHERE status = 1
ORDER BY created_at DESC
LIMIT 2000000, 20;
```

### EXPLAIN 结果

```
+----+--------+---------+------+-------------------+---------+-------+--------+----------+-----------------------+
| id | table  | type    | key  | key_len           | ref     | rows  | filtered| Extra                 |
+----+--------+---------+------+-------------------+---------+-------+--------+-----------------------+
|  1 | t_order| ref     | idx_status_created| 2   | const   | 248K  | 100.00 | Using filesort        |
+----+--------+---------+------+-------------------+---------+-------+--------+-----------------------+
```

### 为什么慢

关键不在 `type=ref`（这还算正常），而在于 **LIMIT 2000000, 20** 的工作方式：

```
MySQL 执行流程:
1. 通过 idx_status_created 找到所有 status=1 的行     → 25 万行
2. 对这些行按 created_at DESC 做 filesort 排序
3. 扫描排序结果，跳过前 2,000,000 行（← 这步是性能杀手）
4. 返回第 2,000,001 ~ 2,000,020 行
```

**第 3 步的"跳过"不是免费的**——MySQL 必须逐行回表读取完整数据，然后丢弃。也就是说，**被丢弃的 200 万行也要付出回表的代价**。

::: tip 核心认知
`LIMIT N, M` 的代价不是 M，而是 **N + M**。偏移量 N 越大，浪费的回表越多。
:::

## 优化方案

### 方案一：延迟关联 + 覆盖索引（推荐）

```sql
-- good.sql
SELECT t.id, t.user_id, t.order_no, t.amount, t.status, t.created_at
FROM t_order t
INNER JOIN (
    SELECT id
    FROM t_order
    WHERE status = 1
    ORDER BY created_at DESC
    LIMIT 2000000, 20
) tmp ON t.id = tmp.id;
```

### 原理

把查询拆成两步：

**第一步（子查询）**：只查 `id`，利用**覆盖索引**避免回表。

```
子查询只 SELECT id → 走 idx_status_created (status, created_at, id)
                     → Extra: Using index（不回表！）
```

虽然仍要扫描索引跳过 200 万条，但**索引扫描是纯内存操作**，不涉及磁盘 I/O 的回表，速度快几个数量级。

**第二步（外层 JOIN）**：用拿到的 20 个 id 精确回表。

```
外层 eq_ref JOIN → 只回表 20 次
```

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 回表次数 | ~2,000,020 次 | **20 次** |
| Extra | Using filesort | Using index（子查询） |
| 耗时 | ~1.2s - 2.5s | **~100ms - 300ms** |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_status_created', rows: '248,097', Extra: 'Using filesort' }"
  :good="{ type: 'index (子查询)', key: 'idx_status_created', rows: '248,097 → 20', Extra: 'Using index → eq_ref 回表20次' }"
  improvement="回表次数从 200 万降到 20，耗时下降 80%+"
/>

### 方案二：游标标记法（适合"上一页/下一页"场景）

如果你的分页不需要"跳转到第 N 页"，只支持上一页/下一页，可以用游标代替 OFFSET：

```sql
-- 记住上一页最后一条的 created_at 和 id
SELECT id, user_id, order_no, amount, status, created_at
FROM t_order
WHERE status = 1
  AND (created_at < '2026-07-10 12:00:00'        -- 上一页最后一条的时间
       OR (created_at = '2026-07-10 12:00:00' AND id < 12345))  -- 处理时间相同的情况
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

**优点**：无论翻到第几页，都是 O(20) 的扫描，性能恒定。
**缺点**：不支持跳页（只能上一页/下一页）；需要前端记住游标。

## 避坑指南

::: warning 注意事项

1. **延迟关联要求排序字段上有索引**。如果 `ORDER BY` 的字段没有索引，子查询也会全表扫描，延迟关联就没有效果。

2. **索引顺序要匹配**。本例中 `idx_status_created (status, created_at)` 的顺序是先等值条件 `status`，后排序字段 `created_at`，这样才能走索引排序。如果反过来建 `(created_at, status)`，`status=1` 的等值条件就用不上索引了。

3. **游标法的坑**：如果排序字段有重复值（比如多行 created_at 相同），必须加上 `id` 作为第二排序键，否则会漏数据或重复数据。

4. **不要用 `SELECT *`**。即使延迟关联的外层也只查需要的字段，减少网络传输和内存占用。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 延迟关联方案 | ✅ 有效 | ✅ 有效 |
| 降序索引 `DESC` | ❌ 解析但忽略，仍 filesort | ✅ 真正支持，可消除 filesort |
| EXPLAIN 格式 | 传统表格式 | 额外支持 TREE 格式，更直观 |

::: tip 8.0 降序索引
如果你的查询是 `ORDER BY created_at DESC`，可以在 8.0 中创建降序索引：
```sql
KEY idx_status_created_desc (status, created_at DESC)
```
这样连子查询的 filesort 也能消除，进一步提升性能。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 01-deep-pagination

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 01-deep-pagination --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 01-deep-pagination --no-seed
```
