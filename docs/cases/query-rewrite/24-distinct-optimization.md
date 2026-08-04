# DISTINCT 优化

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['DISTINCT', '临时表', '覆盖索引', '去重']" />

## 20 万：约 90ms
访问日志表需要按 `user_id` 去重，查出某时间段内有访问记录的用户。看似简单的 `SELECT DISTINCT` 查询，EXPLAIN 却显示 `Using temporary`--MySQL 创建了临时表来做去重，20 万行数据耗时约 90ms。

```sql
-- DISTINCT user_id 去重，visit_time 过滤后无可用索引做有序扫描
SELECT DISTINCT user_id
FROM t_visit_log
WHERE visit_time > '2024-01-01';
```

表上已有 `idx_user (user_id)` 索引，但它无法同时支持 `visit_time` 范围过滤和 `user_id` 去重。优化器只能全表扫描，把满足条件的行写入临时表，利用唯一约束去重。当去重结果较大时，临时表从 MEMORY 引擎转为磁盘临时表，性能骤降。

::: warning 真实场景
DISTINCT 和 GROUP BY 是数据分析中最常用的操作--统计活跃用户、去重 UV、找唯一值。数据量小时代价不明显，数据量大了临时表去重就是性能杀手。很多人不知道，建对索引可以让 MySQL 直接在索引上完成去重，完全免临时表。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: DISTINCT user_id 去重，visit_time 过滤后无可用索引做有序扫描
-- Extra 出现 Using temporary（临时表去重）+ Using filesort
SELECT DISTINCT user_id
FROM t_visit_log
WHERE visit_time > '2024-01-01';
```

### EXPLAIN 结果

```
+----+-------------+--------------+------+---------------+----------+---------+------+--------+----------+------------------------------+
| id | select_type | table        | type | possible_keys | key      | key_len | ref  | rows   | filtered | Extra                        |
+----+-------------+--------------+------+---------------+----------+---------+------+--------+----------+------------------------------+
|  1 | SIMPLE      | t_visit_log  | ALL  | NULL          | NULL     | NULL    | NULL | 198765 |    33.33 | Using temporary; Using where |
+----+-------------+--------------+------+---------------+----------+---------+------+--------+----------+------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | **`ALL`** | 全表扫描 |
| possible_keys | `NULL` | 无可用索引（idx_user 无法支持 visit_time 过滤 + user_id 去重） |
| key | `NULL` | 未使用索引 |
| rows | ~198,765 | 扫描全表 |
| Extra | **`Using temporary`** | **创建临时表做去重！** |

### 为什么慢

`SELECT DISTINCT user_id WHERE visit_time > '2024-01-01'` 需要：

1. **全表扫描**：无索引能同时支持 visit_time 范围过滤和 user_id 去重
2. **临时表去重**：MySQL 把所有满足条件的 `(user_id)` 写入临时表，利用唯一约束去重
3. **临时表可能落盘**：若去重结果较大，临时表从 MEMORY 引擎转为磁盘 MyISAM/InnoDB
4. **额外内存与 I/O 开销**：临时表的写入、去重、读取都是额外成本

执行流程：

```
1. 全表扫描 t_visit_log（20 万行）
2. 逐行判断 visit_time > '2024-01-01'（过滤掉约 2/3）
3. 命中行写入临时表（user_id 作为唯一键去重）
4. 从临时表读取去重后的结果
```

::: warning 何时出现 Using temporary
- DISTINCT / GROUP BY 的列无索引支撑
- DISTINCT 的列与 WHERE 过滤列无共同索引
- 去重列不在索引的最左前缀位置
:::

::: tip 核心认知
DISTINCT/GROUP BY 的列是索引的最左前缀时，优化器使用松散索引扫描（Loose Index Scan），对每个分组只读首行即可去重，免临时表。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 建立联合索引 (user_id, visit_time) 后走 Using index for group-by
-- 需先执行 setup-good.sql 建立索引
SELECT DISTINCT user_id
FROM t_visit_log
WHERE visit_time > '2024-01-01';
```

先执行 setup-good.sql 建立联合索引：

```sql
-- setup-good.sql: 建立联合索引 (user_id, visit_time) 支持去重与范围过滤
ALTER TABLE t_visit_log ADD KEY idx_user_visit (user_id, visit_time);
```

### 原理

联合索引 `idx_user_visit (user_id, visit_time)` 的 B+ 树中，数据按 `user_id` 有序、同 user_id 内按 `visit_time` 有序：

1. **索引有序**：相同 user_id 的行在索引中连续存放
2. **松散索引扫描（Loose Index Scan）**：优化器对每个 user_id 只需读取第一行即可判定该 user_id 存在，跳过同 user_id 的其余行
3. **无需临时表**：`Using index for group-by` 表示直接在索引上完成去重，不创建临时表
4. **范围过滤受益**：visit_time 在索引第二列，可在索引内做范围判断

执行流程（优化后）：

```
1. 从 idx_user_visit 索引扫描（有序）
2. 对每个 user_id：松散读取，遇到 visit_time > '2024-01-01' 即输出该 user_id
3. 跳到下一个 user_id（索引有序，无需全扫）
4. 无临时表、无额外排序
```

### 对比

| | bad.sql (无索引) | good.sql (有索引) |
|---|---|---|
| type | ALL | range |
| rows | ~198,765 | ~66,124 |
| Extra | Using temporary | Using index for group-by |
| 耗时 | ~90 ms | ~15 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '198,765', Extra: 'Using temporary; Using where' }"
  :good="{ type: 'range', key: 'idx_user_visit', rows: '66,124', Extra: 'Using index for group-by' }"
  improvement="消除临时表，松散索引扫描去重，扫描行减少 67%，耗时下降约 6 倍"
/>

## 避坑指南

::: warning 注意事项

1. **索引列顺序很重要**。本案例索引是 `(user_id, visit_time)`：`DISTINCT user_id` 能松散扫描（user_id 是前缀），但 `DISTINCT visit_time` 不行（visit_time 不是前缀）。去重列必须在索引最左前缀位置。

2. **SELECT 列受限**。`Using index for group-by` 要求 SELECT 只包含 DISTINCT 的列（或 MIN/MAX 聚合）。如果 `SELECT DISTINCT user_id, page_url`，松散扫描无法使用，因为 page_url 不在索引中。

3. **临时表不总是坏事**。如果去重结果集很小（如只有几十个不同值），临时表去重也很快。只有数据量大、临时表落盘时才需要优化。

4. **DISTINCT 和 GROUP BY 等价**。`SELECT DISTINCT user_id` 和 `SELECT user_id ... GROUP BY user_id` 在 MySQL 中执行计划相同，优化手段也一样。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 松散索引扫描（Loose Index Scan） | ✅ 支持 | ✅ 支持 |
| `Using index for group-by` | ✅ 支持 | ✅ 支持 |
| 临时表去重 | ✅ 无索引时触发 | ✅ 无索引时触发 |
| 8.0 优化器改进 | - | 8.0 对 GROUP BY 有更多优化策略 |

::: tip Using index for group-by 原理
当 DISTINCT/GROUP BY 的列是索引的最左前缀，且 SELECT 只包含这些列（或 MIN/MAX 聚合）时，优化器使用**松散索引扫描**：对每个分组只读首行，跳过组内其余行。这比紧凑扫描快得多，因为不需要读取所有数据。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 24-distinct-optimization

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 24-distinct-optimization --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 24-distinct-optimization --no-seed
```
