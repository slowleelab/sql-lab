# 软删除设计模式

<CaseMeta difficulty="⭐⭐" category="架构级优化" versions="5.7 & 8.0" :tags="['软删除', 'deleted_at', '联合索引', '查询过滤']" />

## 10 万：20% 已软删除
文档系统采用软删除--用 `deleted_at` 字段标记删除时间而非物理删除行，NULL 表示未删除。查询用户文档时需要带上 `WHERE deleted_at IS NULL` 过滤已删除数据。文档表 10 万行（其中 20% 已软删除），查询某作者的未删除文档却出现 filesort：

```sql
SELECT *
FROM t_document_soft
WHERE author_id = 12345
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
```

表上只有单列索引 `idx_author`，看起来走了索引（type=ref），但 EXPLAIN 显示 `filtered=10.00%` 和 `Using filesort`。这意味着：定位到 author_id=12345 的行后必须回表逐行判断 deleted_at，约 90% 的回表是浪费的（已软删除）；ORDER BY created_at 无索引支撑，还需额外排序。

这就是 **"软删除索引设计不当"** 的经典困境--`deleted_at IS NULL` 没有纳入索引，导致无效回表 + filesort。数据量放大后，某作者有数千上万行文档时，约 90% 的回表是浪费的，filesort 落磁盘更是严重慢查询。

::: warning 真实场景
内容管理、订单管理、用户管理--凡是采用软删除（deleted_at/is_deleted）模式的系统，几乎所有查询都要带 `deleted_at IS NULL` 过滤条件。如果索引设计忽略了这个条件，就会导致大量无效回表和 filesort。某作者文档量大时（千行级），bad 方案需 filesort 千行，代价剧增。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 软删除查询无合适索引，全表扫描 + filesort
-- idx_author 只能定位 author_id，但 deleted_at IS NULL 和 ORDER BY created_at 无法利用
-- deleted_at IS NULL 在 idx_author 上无法过滤，需回表逐行判断；ORDER BY 触发 filesort
SELECT *
FROM t_document_soft
WHERE author_id = 12345
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
```

### EXPLAIN 结果

```
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
| id | select_type | table            | partitions | type | possible_keys | key        | key_len | ref   | rows | filtered | Extra                                        |
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
|  1 | SIMPLE      | t_document_soft  | NULL       | ref  | idx_author    | idx_author | 8       | const |    4 |   10.00 | Using where; Using filesort                  |
+----+-------------+------------------+------------+------+---------------+------------+---------+-------+------+----------+----------------------------------------------+
```

### 为什么慢

看似走了索引（type=ref），但有两个严重问题：

**1. deleted_at IS NULL 无法在索引层过滤**

`idx_author` 只包含 `author_id`，不包含 `deleted_at`。优化器定位到 `author_id=12345` 的行后，必须**回表**读取完整行，再在 server 层用 `deleted_at IS NULL` 过滤。已软删除的行做了**无效回表**。

**2. ORDER BY created_at 触发 filesort**

`idx_author` 不包含 `created_at`，索引中数据不按 created_at 排序。优化器无法利用索引的有序性，必须把过滤后的行全部取出，再用 **filesort**（额外排序）按 created_at DESC 排序。

```
执行流程:
  1. idx_author 定位 author_id=12345 的所有行（预估约 4 行）
  2. 逐行回表读完整数据
  3. server 层用 deleted_at IS NULL 过滤（丢掉已删除行，filtered 仅 10%）
  4. 对剩余行做 filesort（按 created_at DESC 排序）
  5. 取 LIMIT 20 返回

问题:
  - 步骤2: 已删除行无效回表（I/O 浪费）
  - 步骤4: filesort 占用 sort_buffer，数据多时可能落临时表磁盘
```

本案例 author_id=12345 只有约 4 行，filesort 开销小。但生产环境中某作者可能有多达数千上万行文档，filtered 仅 10% 意味着约 90% 的回表是浪费的，filesort 在结果集大时可能使用磁盘临时表，代价剧增。

实际耗时：约 **6 ms**（实测 MySQL 8.0.46，author_id=12345 仅约 4 行）。某作者文档量大时（如千行级），耗时可达 **50-200 ms**。

::: tip 核心认知
软删除场景下，几乎所有查询都带 `deleted_at IS NULL`。它应作为联合索引的**等值列**纳入索引设计，而非被忽略。`IS NULL` 属于等值类匹配，放在中间列可让后续列（如排序字段）保持有序。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 走联合索引 idx_author_deleted_created（需先执行 setup-good.sql 建索引）
-- (author_id, deleted_at, created_at) 三列联合索引完美覆盖查询:
--   author_id=12345 等值定位 -> deleted_at IS NULL 过滤 -> created_at 已按索引有序
-- 无需 filesort，LIMIT 20 可提前终止扫描
SELECT *
FROM t_document_soft
WHERE author_id = 12345
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 20;
```

### 建索引语句

```sql
-- setup-good.sql: 为软删除查询设计联合索引
-- (author_id, deleted_at, created_at) 覆盖 WHERE + ORDER BY，避免 filesort
-- author_id 等值定位 -> deleted_at IS NULL 过滤 -> created_at 已有序（省去排序）
ALTER TABLE t_document_soft
    ADD KEY idx_author_deleted_created (author_id, deleted_at, created_at);
```

> 需先执行 `setup-good.sql` 创建联合索引 `idx_author_deleted_created`，再执行 `good.sql`。

### 原理

联合索引 `(author_id, deleted_at, created_at)` 完美覆盖了查询的三个条件：

```
索引: (author_id, deleted_at, created_at)
       ^^^^^^^^^  ^^^^^^^^^^  ^^^^^^^^^^
       等值定位    IS NULL过滤   排序依据
```

1. **author_id 等值定位**（最左列）：用 `author_id = 12345` 精准定位，索引 B+ 树直接跳到该区间
2. **deleted_at IS NULL 过滤**（第二列）：在 author_id 区间内，deleted_at 有序排列，NULL 值集中在区间头部/尾部，可直接范围扫描过滤，**无需回表判断**
3. **created_at 有序**（第三列）：在 (author_id, deleted_at) 确定的子区间内，created_at 已按索引顺序排列，**ORDER BY created_at DESC 直接逆向扫描索引即可**，无需 filesort
4. **LIMIT 20 提前终止**：索引有序 + LIMIT，扫够 20 行即停，不必处理全部匹配行

::: tip 为什么 deleted_at 放在 created_at 前面
软删除场景下，几乎所有查询都带 `deleted_at IS NULL`。把它放在 `created_at` 前面：
- 等值/IS NULL 条件放在中间列，让后续列（created_at）仍能利用索引有序性
- 若顺序是 `(author_id, created_at, deleted_at)`，则 created_at 在中间，deleted_at IS NULL 在末尾，ORDER BY created_at 仍会 filesort（范围列后无法保序）

**核心原则**：等值列在前，范围/排序列在后。`IS NULL` 属于等值类匹配，可让后续列保持有序。
:::

### 对比

| 指标 | bad (idx_author) | good (联合索引) | 提升 |
|------|------------------|-----------------|------|
| type | ref | ref | 均走索引定位 |
| key | idx_author | idx_author_deleted_created | 选择更优联合索引 |
| key_len | 8（仅 author_id） | 14（author_id+deleted_at） | 多用一列过滤 |
| rows | ~4 | ~3 | **减少 25%** |
| filtered | 10.00% | 100% | 索引层已过滤完毕 |
| Extra | Using where; Using filesort | Using where; Backward index scan | **消除 filesort** |
| filesort | 有 | 无 | 消除 |
| 耗时 | ~6 ms | ~1 ms | **约 6 倍** |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_author', rows: '4', Extra: 'Using where; Using filesort（filtered 10%，大量无效回表 + 排序）' }"
  :good="{ type: 'ref', key: 'idx_author_deleted_created', rows: '3', Extra: 'Using where; Backward index scan（filtered 100%，无 filesort）' }"
  improvement="消除 filesort，filtered 从 10% 到 100%，耗时下降约 6 倍"
/>

> 本案例 author_id=12345 仅约 4 行，filesort 开销小，单次耗时差距不明显。作者文档量大时差距更显著：千行级数据 bad 方案需 filesort 千行，good 方案利用索引有序性 + LIMIT 仅扫描需要的行数。

## 避坑指南

::: warning 注意事项

1. **软删除字段要纳入索引**：所有查询都带 `deleted_at IS NULL`，它应作为联合索引的等值列，而非被忽略。

2. **等值列在前，排序列在后**：`(author_id, deleted_at, created_at)` 顺序让排序走索引，避免 filesort。

3. **不要只建单列索引**：仅 `idx_author` 会导致 deleted_at 过滤回表 + created_at filesort。

4. **考虑部分索引优化**：若已删除数据占比高，可考虑把已删除数据归档到历史表，减少主表体积。

5. **deleted_at 用 NULL 而非 0/1**：NULL 语义清晰（未删除=未设置删除时间），且 `IS NULL` 可走索引；若用 `is_deleted TINYINT`，0/1 选择性极低，单独建索引意义不大。

6. **定期清理软删除数据**：长期累积的软删除行会膨胀表和索引，应定期归档或物理清理。

7. **唯一约束要考虑软删除**：如要求同一 author 下 title 唯一，唯一索引应包含 deleted_at，否则软删除后无法重建同名文档。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 联合索引方案 | ✅ 有效 | ✅ 有效 |
| 降序索引优化 | ⚠️ Backward index scan（不支持建索引时写 DESC 关键字） | ✅ 真降序索引（可建 `INDEX (col DESC)`，混合 ASC/DESC 排序不需 filesort） |
| filtered 过滤 | ✅ 支持 | ✅ 支持 |
| 执行计划结构 | 一致 | 一致 |

::: tip 8.0 逆向索引扫描
执行计划结构在两个版本上一致，联合索引方案都有效。差异在于：8.0 的 Extra 显示 `Backward index scan`（逆向索引扫描优化 ORDER BY DESC），直接逆向扫描索引消除 filesort；5.7 显示 `Using filesort`（5.7 无降序索引优化，需额外排序）。核心的联合索引设计原则与版本无关。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 58-soft-delete-pattern

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 58-soft-delete-pattern --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 58-soft-delete-pattern --no-seed
```
