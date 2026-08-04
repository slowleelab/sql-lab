# TEXT/BLOB 字段性能陷阱

<CaseMeta difficulty="⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['TEXT', 'BLOB', '回表', 'SELECT *', '溢出页']" />

## 只有 10 万行却加载 100ms：TEXT/BLOB 的隐形开销
内容管理系统的文章列表页，每次加载都要等 **100ms 以上**。表里只有 10 万行文章，查询走了索引，只取 20 条，看起来不该这么慢：

```sql
SELECT * FROM t_article
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
```

排查发现，文章表有个 `content TEXT` 字段存正文，平均 2KB。`SELECT *` 把这个大字段也一起读了出来--即使前端列表页根本不展示正文。

这就是 **"TEXT/BLOB 字段陷阱"**--大字段存储在溢出页（off-page）中，`SELECT *` 回表时会触发溢出页链的随机 I/O，把本该很快的查询拖慢数倍。

::: warning 真实场景
任何包含 TEXT/BLOB 大字段的表：文章正文、商品详情、附件内容、日志原文。只要写 `SELECT *`，就会把这些大字段全部读入内存，列表页、导出接口、批量查询无一幸免。
:::

## 问题分析

### bad.sql

```sql
-- SELECT * 查询：回表时连 TEXT 大字段一起读入，每行约 2KB 的 content 被加载
-- 虽然只取 20 行，但 InnoDB 回表时 TEXT 可能存储在溢出页（off-page），
-- 读取 TEXT 需要额外的磁盘 I/O 追踪溢出页链，大幅增加延迟
SELECT * FROM t_article
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
```

### EXPLAIN 结果

```
+----+-----------+-----------+------+----------------------+---------+-------+--------+----------+-----------------------+
| id | table     | type      | key  | key_len              | ref     | rows  | filtered| Extra                 |
+----+-----------+-----------+------+----------------------+---------+-------+--------+-----------------------+
|  1 | t_article | ref       | idx_category_created| 82   | const   | 20000 | 100.00 | Backward index scan   |
+----+-----------+-----------+------+----------------------+---------+-------+--------+-----------------------+
```

执行计划看起来正常：`type=ref` 走了 `idx_category_created` 索引，`rows=20000` 预估扫描该分类行数。**问题不在索引定位，而在回表读取的数据量。**

### 为什么慢

InnoDB 对 TEXT/BLOB 的存储分三种情况（取决于行格式和字段大小）：

- **REDUNDANT/COMPACT 格式**：前 768 字节存行内，剩余存溢出页
- **DYNAMIC/COMPRESSED 格式**（5.7/8.0 默认）：行内只存 20 字节指针，全部内容存溢出页
- 读取 TEXT 时需要先读行内指针，再跳转到溢出页读取实际内容

`SELECT *` 的回表流程：

```
1. 通过 idx_category_created 定位到 category='技术' 的行，按 created_at 降序扫描
2. 逐行回表到聚簇索引读取完整行数据 -- 包括约 2KB 的 content TEXT 字段
3. TEXT 字段存溢出页（DYNAMIC 格式行内只有指针）
4. 读取 TEXT 需追踪溢出页链（BLOB page chain），产生大量随机 I/O
5. 虽然最终只返回 20 行，但前 20 行每一行的回表都要读取溢出页
```

数据传输量对比：

| 方案 | 每行数据量 | 20 行总量 | 说明 |
|------|-----------|-----------|------|
| SELECT * | ~2.1 KB | ~42 KB | 含 2KB TEXT + 元数据，需读溢出页 |
| 只查必要列 | ~0.3 KB | ~6 KB | 无 TEXT，数据量减少约 85% |

::: tip 核心认知
即使不需要 TEXT 字段，`SELECT *` 也会触发溢出页的 I/O。大字段的代价不在存储，而在每次读取时的随机 I/O 追踪。回表读的不是一行，而是一行 + 一串溢出页。
:::

## 优化方案

### good.sql

```sql
-- 只查必要列（不含 content），减少回表数据量
-- 不查 TEXT 字段时，InnoDB 回表读取聚簇索引行仍需定位到行数据，
-- 但不需要追踪 TEXT 溢出页链读取大文本内容，网络传输量也大幅减少
-- 进一步优化可将 views 放入覆盖索引实现完全 Using index（见 setup-good.sql）
SELECT id, title, author, category, views, created_at
FROM t_article
WHERE category = '技术'
ORDER BY created_at DESC
LIMIT 20;
```

### 原理

执行计划与 bad 方案看似相同（都走 `ref + idx_category_created`，都需要回表），但**回表读取的数据量天差地别**：

1. bad 方案回表读 `SELECT *`：包含 2KB 的 TEXT content -> 需追踪溢出页链
2. good 方案回表读 6 个小字段：不含 TEXT -> 聚簇索引行内数据即可满足，**无需读溢出页**
3. 网络传输量从 ~42 KB 降至 ~6 KB，减少约 85%
4. 内存占用大幅降低，Buffer Pool 命中率提升

### 进一步优化：覆盖索引

如果将 `views` 也加入索引，可实现完全的覆盖索引（Using index），连回表都省掉：

```sql
-- 将 views 加入索引，列表页查询可走覆盖索引
ALTER TABLE t_article ADD KEY idx_category_created_views (category, created_at, views);
```

此时 Extra 会显示 `Using index`，完全不需要回表聚簇索引，也不读溢出页。

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_category_created', rows: '20,000', Extra: 'Backward index scan + 回表读 TEXT 溢出页' }"
  :good="{ type: 'ref', key: 'idx_category_created', rows: '20,000', Extra: 'Backward index scan + 回表不读溢出页' }"
  improvement="执行计划相同，但回表数据量减少 85%，溢出页 I/O 消除，耗时下降约 3.4 倍"
/>

## 量化对比

| 指标 | bad (SELECT *) | good (只查必要列) | 提升 |
|------|----------------|-------------------|------|
| 耗时 | ~120 ms | ~35 ms | **约 3.4 倍** |
| 每行数据量 | ~2.1 KB | ~0.3 KB | **减少 85%** |
| 20 行传输量 | ~42 KB | ~6 KB | **减少 85%** |
| 溢出页 I/O | 需要 | 不需要 | **消除** |

## 避坑指南

::: warning 注意事项

1. **永远不要在业务查询中使用 SELECT \***：尤其是含 TEXT/BLOB 字段的表，明确列出所需列。

2. **TEXT/BLOB 字段单独拆表**：将大字段拆到扩展表（如 `t_article_content`），主表只存元数据。列表查询主表，详情页 JOIN 扩展表。

3. **列表页和详情页分离**：列表页不查 content，详情页按主键单独查 content。

4. **注意 VARCHAR 也可能溢出**：VARCHAR 超过行大小限制时同样会溢出到 off-page，不要以为只有 TEXT/BLOB 才有这个问题。

5. **监控 off-page I/O**：通过 `SHOW ENGINE INNODB STATUS` 关注 BLOB page 的读取情况，发现异常及时优化。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 默认行格式 | DYNAMIC | DYNAMIC |
| TEXT 存储机制 | 溢出页 | 溢出页（一致） |
| 降序索引扫描 | Using filesort | Backward index scan |
| 优化方案效果 | ✅ 有效 | ✅ 有效 |

::: tip 行格式说明
5.7 和 8.0 默认行格式都是 DYNAMIC，TEXT 存储机制完全相同（行内只存指针，内容存溢出页）。优化原理一致。

差异仅在 EXPLAIN 的 Extra 显示：8.0 对 `ORDER BY ... DESC` 显示 `Backward index scan`（逆向索引扫描，无需排序）；5.7 无降序索引优化，显示 `Using filesort`。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 43-text-blob-pitfall

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 43-text-blob-pitfall --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 43-text-blob-pitfall --no-seed
```
