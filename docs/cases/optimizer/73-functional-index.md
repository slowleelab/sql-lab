# 函数索引优化 DATE 函数查询

<CaseMeta difficulty="⭐⭐" category="优化器与8.0新特性" versions="8.0" :tags="['函数索引', '索引失效', 'DATE函数', '8.0新特性']" />

## 场景痛点

访问日志表按日期查询是再常见不过的需求--"查看某天的访问记录"。开发者很自然地写出 `WHERE DATE(created_at) = '2024-01-15'`，`created_at` 字段上明明建了索引，但查询却慢得离谱，EXPLAIN 一看竟然是全表扫描。

```sql
-- 看似合理的写法：按日期查访问日志
SELECT id, user_id, ip_addr, created_at
FROM t_access_log
WHERE DATE(created_at) = '2024-01-15';
```

15 万行数据下耗时约 150ms，`type=ALL` 全表扫描。问题出在对索引列施加了 `DATE()` 函数--索引存的是原始 `DATETIME` 值，`DATE()` 把时间部分截断后产生派生值，B+Tree 索引无法定位，优化器只能逐行计算函数再比较。

更隐蔽的是，这类问题往往在数据量小时不明显（全表扫描也就几十毫秒），数据增长到百万级后突然变成秒级慢查询，触发告警时才被发现。

::: warning 真实场景
日志表按日期筛选、订单表按月统计、用户表按注册日查询--只要在 `WHERE` 条件里对索引列套了函数（`DATE()`、`YEAR()`、`MONTH()`、`UPPER()` 等），索引都会失效。这是最常见、也最容易忽视的索引失效原因。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 对索引列 created_at 施加 DATE() 函数，索引失效，退化为全表扫描
-- idx_created 索引无法被利用，因为 DATE(created_at) 是派生值，索引存的是原始 DATETIME
SELECT id, user_id, ip_addr, created_at
FROM t_access_log
WHERE DATE(created_at) = '2024-01-15';
```

### EXPLAIN 结果

```
+----+-------------+--------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table        | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_access_log | ALL  | NULL          | NULL | NULL    | NULL | 149752 |   100.00 | Using where |
+----+-------------+--------------+------+---------------+------+---------+------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | **全表扫描** |
| key | NULL | 索引完全未被使用 |
| possible_keys | NULL | 优化器认为没有可用索引 |
| rows | ~149,752 | 扫描全部 15 万行 |
| Extra | `Using where` | 逐行计算 DATE() 后再过滤 |

### 为什么慢

`idx_created` 索引存储的是 `created_at` 的原始 DATETIME 值（如 `2024-01-15 10:30:00`）。查询条件 `DATE(created_at) = '2024-01-15'` 是对列施加函数后的派生值。

索引是 B+Tree，按原始值排序。`DATE(created_at)` 把时间部分截断后，相邻的索引值可能映射到不同日期，也可能不相邻的值映射到同一日期，导致索引无法用于范围定位。

因此优化器只能：
1. 全表扫描每一行
2. 对每行计算 `DATE(created_at)`
3. 比较是否等于目标日期

15 万行全部计算 + 比较，开销巨大。

::: warning 索引失效的常见函数
对索引列施加以下函数都会导致索引失效：`DATE()`、`YEAR()`、`MONTH()`、`UPPER()`、`LOWER()`、`LEFT()`、`SUBSTRING()`、`FLOOR()` 等。任何改变原始值或破坏有序性的运算都会让 B+Tree 索引无法定位。
:::

::: tip 核心认知
对索引列施加函数 = 索引失效。索引存的是原始值，函数产生派生值，B+Tree 无法对派生值定位。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 改写为范围查询，避免对索引列施加函数，可走 idx_created 范围扫描
-- 也可用 setup-good.sql 的函数索引 ((DATE(created_at))) 直接支持原写法
SELECT id, user_id, ip_addr, created_at
FROM t_access_log
WHERE created_at >= '2024-01-15 00:00:00'
  AND created_at <  '2024-01-16 00:00:00';
```

如果无法改写 SQL（如框架生成的查询），可执行 setup-good.sql 创建函数索引：

```sql
-- setup-good.sql: 创建 8.0 函数索引，直接对 DATE(created_at) 表达式建索引
-- 创建后，原 bad.sql 的 WHERE DATE(created_at) = '...' 写法也能命中此索引
-- 注: 函数索引仅 MySQL 8.0.13+ 支持
ALTER TABLE t_access_log ADD KEY idx_date_created ((DATE(created_at)));
```

### 原理

改写为 `created_at >= '2024-01-15 00:00:00' AND created_at < '2024-01-16 00:00:00'` 后：
1. 条件是对**原始索引列**的范围比较，没有施加函数
2. B+Tree 索引天然支持范围查询，直接定位到 `2024-01-15 00:00:00` 的位置
3. 顺序扫描到 `2024-01-16 00:00:00` 前停止

索引有序性得以利用，只需扫描约 408 行（当天数据），而非全表 15 万行。

函数索引方案则是让 8.0 直接对 `DATE(created_at)` 这个表达式建索引，B+Tree 按日期值排序，原写法 `WHERE DATE(created_at) = '...'` 也能命中。

### 对比

| | bad.sql (DATE 函数) | good.sql (范围查询) |
|---|---|---|
| type | ALL | range |
| rows | ~149,752 | ~408 |
| Extra | Using where | Using index condition |
| 耗时 | ~150 ms | ~3 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '149,752', Extra: 'Using where' }"
  :good="{ type: 'range', key: 'idx_created', rows: '408', Extra: 'Using index condition' }"
  improvement="全表扫描变范围扫描，扫描行从 15 万降到 408，耗时下降 50 倍"
/>

## 避坑指南

::: warning 注意事项

1. **优先改写 SQL 而非建函数索引**。`DATE(col) = x` 改为 `col >= x AND col < x+1` 兼容所有 MySQL 版本，无需额外索引维护开销。函数索引是"无法改写时的补救手段"。

2. **函数索引仅 8.0.13+ 支持**。5.7 和 8.0 早期版本不支持函数索引，只能改写 SQL。

3. **警惕隐式函数调用**。除了显式的 `DATE()`，`WHERE varchar_col = 123`（字符串列与数字比较）也会触发隐式类型转换导致索引失效。确保比较的两边类型一致。

4. **函数索引不适用于所有场景**。如果同一个列有多种函数查询模式（`DATE()`、`YEAR()`、`MONTH()`），每种都要单独建函数索引，索引膨胀反而拖慢写入。此时改写 SQL 是更优解。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 函数索引 `((expr))` | ❌ 不支持 | ✅ 8.0.13+ 支持 |
| 改写为范围查询 | ✅ 有效 | ✅ 有效 |
| `DATE()` 等函数致索引失效 | ✅ 同样失效 | ✅ 同样失效 |
| 降序索引 | ❌ 忽略 DESC | ✅ 真正支持 |

::: tip 两种优化策略
1. **改写 SQL（推荐）**：将 `DATE(col) = x` 改为 `col >= x AND col < x+1`，兼容所有版本，无需额外索引
2. **函数索引（8.0+）**：不改 SQL，直接对表达式建索引，适合无法改写或查询模式多样的场景
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 73-functional-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 73-functional-index --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 73-functional-index --no-seed
```
