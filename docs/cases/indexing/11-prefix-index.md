# 前缀索引优化长字符串

<CaseMeta difficulty="⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['前缀索引', 'VARCHAR', '索引空间', '选择性']" />

## 8mb变慢
URL 日志表的 `url` 字段是 `VARCHAR(255)`，为了支持按 URL 等值查询，直接建了全列索引 `idx_url (url)`。查询确实走索引了，但 `key_len` 高达 1022 字节--`utf8mb4` 下每个字符最多 4 字节，255×4+2=1022。15 万行数据的索引体积约 150MB，buffer pool 被大索引挤占，热数据频繁被驱逐，写入也因为 B+ 树节点过大而变慢。

```sql
-- URL 等值查询，全列索引 key_len = 1022 字节
SELECT id, url, visit_count, created_at
FROM t_url_log
WHERE url = 'https://www.example.com/p/000123/detail?id=45678';
```

实际上 URL 的前 20 个字符（`https://www.example.com/`）已经能区分绝大多数记录，完整的 255 字符索引纯属浪费。前缀索引 `url(20)` 只索引前 20 个字符，`key_len` 从 1022 降到 82 字节，索引体积缩小约 12 倍。

::: warning 真实场景
URL、邮箱、文件路径、UUID--这些长字符串字段在建索引时最容易"暴力全列索引"。数据量小时没感觉，数据量大了索引空间、buffer pool 占用、写入延迟全都会暴露出来。前缀索引是长字符串字段的标配优化手段。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: url 列建了全索引 idx_url (url)，key_len 高达 1022 字节
-- 全列索引占用空间大，写入与 buffer pool 压力大
SELECT id, url, visit_count, created_at
FROM t_url_log
WHERE url = 'https://www.example.com/p/000123/detail?id=45678';
```

### EXPLAIN 结果

```
+----+-------------+----------+------+---------------+--------+---------+-------+------+----------+-------+
| id | select_type | table    | type | possible_keys | key    | key_len | ref   | rows | filtered | Extra |
+----+-------------+----------+------+---------------+--------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_url_log| ref  | idx_url       | idx_url| 1022    | const |    1 |   100.00 | NULL  |
+----+-------------+----------+------+---------------+--------+---------+-------+------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 等值匹配索引 |
| key | `idx_url` | 使用全列索引 |
| key_len | **`1022`** | **VARCHAR(255) utf8mb4 全列索引 = 255×4+2 = 1022 字节** |
| rows | 1 | 命中 1 行 |

### 为什么慢

`url VARCHAR(255)` 在 `utf8mb4` 下，每个字符最多 4 字节，全列索引 key_len 高达 **1022 字节**：

1. **索引体积大**：每条索引记录占 1 KB，15 万行约需 150 MB 索引空间
2. **buffer pool 占用高**：大索引挤占缓存，热数据易被驱逐
3. **写入变慢**：B+ 树节点大，分裂与维护成本高
4. **多数查询用不到完整长度**：URL 前 20 字符已能区分绝大多数记录

::: warning 前缀索引的代价
前缀索引**不能**用作覆盖索引（`Using index`），因为索引中只存了前缀，无法判断完整值是否匹配，必须回表。本案例 SELECT 了 url 列，回表无法避免，但等值查找的定位效率依然提升。
:::

::: tip 核心认知
长字符串全列索引的 `key_len` = 字符数 × 4（utf8mb4）+ 2。前缀索引只索引前 N 个字符，在选择性足够的前提下大幅缩减索引体积。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 改用前缀索引 idx_url_prefix (url(20))，key_len 仅 82 字节
-- 需先执行 setup-good.sql 删除全索引并建立前缀索引
SELECT id, url, visit_count, created_at
FROM t_url_log
WHERE url = 'https://www.example.com/p/000123/detail?id=45678';
```

先执行 setup-good.sql 替换索引：

```sql
-- setup-good.sql: 删除全列索引，建立前缀索引 url(20)
ALTER TABLE t_url_log DROP INDEX idx_url;
ALTER TABLE t_url_log ADD KEY idx_url_prefix (url(20));
```

### 原理

前缀索引 `url(20)` 只索引 URL 的前 20 个字符：

1. **key_len 从 1022 降到 82**：索引体积缩小约 12 倍
2. **空间大幅节省**：15 万行索引空间从 ~150 MB 降到 ~12 MB
3. **buffer pool 友好**：小索引常驻内存，缓存命中率高
4. **写入更快**：B+ 树节点小，插入与分裂成本降低

前缀长度选择方法--计算不同前缀长度的选择性，选择接近 1 的最小长度：

```sql
SELECT
    COUNT(DISTINCT LEFT(url, 10)) / COUNT(*) AS sel_10,
    COUNT(DISTINCT LEFT(url, 20)) / COUNT(*) AS sel_20,
    COUNT(DISTINCT LEFT(url, 30)) / COUNT(*) AS sel_30,
    COUNT(DISTINCT url) / COUNT(*)          AS sel_full
FROM t_url_log;
```

| 前缀长度 | 选择性 | 评价 |
|----------|--------|------|
| 10 | ~0.50 | 区分度不足 |
| 20 | ~0.95 | 接近全列，推荐 |
| 30 | ~0.99 | 略有冗余 |
| full | 1.00 | 浪费空间 |

### 对比

| | bad.sql (全索引) | good.sql (前缀索引) |
|---|---|---|
| key_len | 1022 字节 | 82 字节 |
| 索引空间 | ~150 MB | ~12 MB |
| 查询命中行数 | 1 | 1 |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_url', rows: '1', Extra: 'key_len=1022' }"
  :good="{ type: 'ref', key: 'idx_url_prefix', rows: '1', Extra: 'key_len=82' }"
  improvement="key_len 从 1022 降到 82，索引空间缩减 92%"
/>

## 避坑指南

::: warning 注意事项

1. **前缀索引不能作为覆盖索引**。索引中只存了前缀，无法判断完整值是否匹配，必须回表验证。如果查询只需要索引列且希望走 `Using index`，前缀索引做不到。

2. **不支持 ORDER BY 完整列排序**。前缀索引不保证完整值的有序性，`ORDER BY url` 无法利用前缀索引排序。

3. **前缀长度要基于实际数据计算**。不同业务数据的区分度不同，用 `COUNT(DISTINCT LEFT(col, N)) / COUNT(*)` 计算选择性，选择接近 1 的最小长度。盲目选固定长度可能区分度不足。

4. **前缀索引对 LIKE 前缀匹配有效**。`WHERE url LIKE 'https://%'` 能走前缀索引，但 `WHERE url LIKE '%example%'`（中间匹配）不行--这与全列索引的限制一致。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 前缀索引 | ✅ 支持 | ✅ 支持 |
| 前缀长度选择 | 手动计算选择性 | 手动计算选择性 |
| 函数索引替代方案 | ❌ 不支持 | ✅ 可对表达式建索引 |
| 覆盖索引限制 | 前缀索引不支持 | 前缀索引不支持 |

::: tip 前缀索引适用场景
适合长字符串（URL、邮箱、路径）的等值/前缀匹配查询。注意：
- 不支持 `ORDER BY url`（索引不保证完整值有序）
- 不能作为覆盖索引
- 对 `WHERE url LIKE 'https://%'` 同样有效（前缀匹配）
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 11-prefix-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 11-prefix-index --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 11-prefix-index --no-seed
```
