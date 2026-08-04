# 优化器 Hint 实战

<CaseMeta difficulty="⭐⭐" category="优化器" versions="5.7 & 8.0" :tags="['USE INDEX', 'FORCE INDEX', 'IGNORE INDEX', '优化器选错索引']" />

## 优化器突然换索引：2ms 飙到 800ms，HINT 强制纠正
线上某个查询突然变慢，排查发现优化器换了一个索引。原本走 `idx_user_created`（10 行扫描）的查询，突然改走 `idx_status`（35 万行扫描），耗时从 2ms 飙到 800ms。数据分布变化导致统计信息偏差，优化器"聪明反被聪明误"。

```sql
-- 优化器可能误选 idx_status，导致 filesort
SELECT * FROM t_order
WHERE user_id = 100 AND status = 1
ORDER BY created_at DESC
LIMIT 10;
```

::: warning 真实场景
优化器选错索引是 DBA 的常见噩梦。触发原因包括：数据分布变化、统计信息过期、ANALYZE TABLE 时机不对。SQL 本身没问题，加索引也不需要，只需要告诉优化器"用哪个索引"。
:::

## 问题分析

### bad.sql

```sql
SELECT * FROM t_order
WHERE user_id = 100 AND status = 1
ORDER BY created_at DESC
LIMIT 10;
```

### EXPLAIN 结果

```
-- 优化器误选 idx_status
+----+-------------+---------+------+-------------------+------------+---------+--------+----------+----------------+
| id | select_type | table   | type | key               | key_len    | rows    |filtered| Extra          |
+----+-------------+---------+------+-------------------+------------+---------+--------+----------------+
|  1 | SIMPLE      | t_order | ref  | idx_status        | 1          | 349872  |  10.00 | Using filesort |
+----+-------------+---------+------+-------------------+------------+---------+--------+----------------+
```

### 为什么慢

两个可选索引的对比：

| 索引 | 过滤能力 | 排序能力 | 扫描行数 | filesort |
|------|---------|---------|---------|----------|
| `idx_status(status)` | 过滤 status=1（~35万行） | ❌ 无法排序 | ~349,872 | ✅ 需要 |
| `idx_user_created(user_id, created_at)` | 过滤 user_id=100（~10行） | ✅ 索引有序 | ~10 | ❌ 不需要 |

优化器误选 `idx_status`：扫描 35 万行 -> 回表过滤 `user_id=100`（只剩 10 行）-> **filesort** 排序 -> 取前 10 行。绝大部分扫描和回表都被丢弃。

## 优化方案

### good.sql

```sql
-- 使用 USE INDEX 强制使用 idx_user_created
SELECT * FROM t_order USE INDEX (idx_user_created)
WHERE user_id = 100 AND status = 1
ORDER BY created_at DESC
LIMIT 10;
```

### 原理

`USE INDEX (idx_user_created)` 告诉优化器只考虑指定索引：

1. `idx_user_created(user_id, created_at)` 同时满足：
   - `WHERE user_id = 100`：索引第一列等值匹配
   - `ORDER BY created_at DESC`：索引第二列有序，直接反向读取
2. 扫描 `user_id=100` 的约 10 行，索引有序直接取前 10 行
3. 回表过滤 `status=1`，由于只有约 10 行，回表开销极小

### 对比

| | bad.sql（误选 idx_status） | good.sql（USE INDEX） |
|---|---|---|
| key | idx_status | idx_user_created |
| rows | ~349,872 | ~10 |
| Extra | Using filesort | Using where |
| 耗时 | ~800 ms | ~2 ms |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_status', rows: '349,872', Extra: 'Using filesort' }"
  :good="{ type: 'ref', key: 'idx_user_created', rows: '10', Extra: 'Using where（索引有序，无 filesort）' }"
  improvement="扫描行数从 35 万降到 10，消除 filesort，耗时下降 400 倍"
/>

## 避坑指南

::: warning 注意事项

1. **三种 Hint 的强度不同**：
   - `USE INDEX (idx)`：建议使用，优化器可忽略（如果代价更高）
   - `FORCE INDEX (idx)`：强制使用，优化器必须遵守
   - `IGNORE INDEX (idx)`：禁止使用指定索引

2. **优先用 USE 而非 FORCE**。USE INDEX 给优化器留有余地，极端情况下仍可选择全表扫描。

3. **Hint 是临时方案**。根因是统计信息不准，应定期执行 `ANALYZE TABLE` 更新统计信息。

4. **8.0 优化器改进**。8.0 的直方图统计（见 [案例 74](./74-histogram-statistics)）可以更准确地估计选择性，减少选错索引的概率。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| USE/FORCE/IGNORE INDEX | ✅ 支持 | ✅ 支持 |
| 直方图统计 | ❌ 不支持 | ✅ 支持，减少选错概率 |
| 优化器 Hint 增强 | 基础 | ✅ 新增 SET_VAR 等语法 |
| ANALYZE TABLE | 采样统计 | ✅ 支持直方图，统计更准 |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 77-optimizer-hint

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 77-optimizer-hint --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 77-optimizer-hint --no-seed
```
