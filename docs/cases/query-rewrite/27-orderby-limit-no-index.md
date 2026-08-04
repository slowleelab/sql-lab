# ORDER BY LIMIT 无索引优化

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['ORDER BY', 'LIMIT', 'filesort', '排序优化']" />

## 取最新 10 条却排序 20 万行：浪费率 99.995%
消息表按 `created_at` 倒序取最新 10 条--再常见不过的查询。但 `created_at` 上没有索引，EXPLAIN 显示 `type=ALL` 全表扫描 + `Using filesort`。20 万行数据全部读入内存排序，最后只取 10 条，浪费率 99.995%。

```sql
-- created_at 无索引，ORDER BY DESC LIMIT 需全表扫描 + filesort
SELECT id, user_id, content, created_at
FROM t_message
ORDER BY created_at DESC
LIMIT 10;
```

耗时约 150ms，看起来还能接受，但 20 万行数据很可能超过默认 `sort_buffer_size`（256KB），触发磁盘排序后性能骤降。数据量再大一些就是秒级慢查询。而加了索引后，B+ 树天然有序，只需从索引末尾反向扫描 10 个叶子节点，耗时降到约 1ms。

::: warning 真实场景
"取最新 N 条"是几乎所有消息/动态/日志系统的标配查询。数据量小时 filesort 无感，数据增长后突然变成性能瓶颈。更隐蔽的是，高并发时多个 filesort 同时占用 sort_buffer，内存压力大，可能引发连锁雪崩。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: created_at 无索引，ORDER BY DESC LIMIT 需全表扫描 + filesort
SELECT id, user_id, content, created_at
FROM t_message
ORDER BY created_at DESC
LIMIT 10;
```

### EXPLAIN 结果

```
+----+-------------+-----------+------+---------------+------+---------+------+--------+----------+----------------+
| id | select_type | table     | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra          |
+----+-------------+-----------+------+---------------+------+---------+------+--------+----------+----------------+
|  1 | SIMPLE      | t_message | ALL  | NULL          | NULL | NULL    | NULL | 198624 |   100.00 | Using filesort |
+----+-------------+-----------+------+---------------+------+---------+------+--------+----------+----------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | **`ALL`** | 全表扫描 |
| possible_keys | `NULL` | 无可用索引（idx_user 无法支持 created_at 排序） |
| key | `NULL` | 未使用索引 |
| rows | ~198,624 | 扫描全表 20 万行 |
| Extra | **`Using filesort`** | **文件排序！**全表数据排序后取前 10 |

### 为什么慢

`ORDER BY created_at DESC LIMIT 10` 在无索引时的执行流程：

1. **全表扫描**：读取全部 20 万行数据到内存
2. **filesort 排序**：对 20 万行按 created_at 降序排序
3. **取前 10 条**：排序完成后只取 10 条

filesort 的代价：

| filesort 类型 | 触发条件 | 代价 |
|---------------|----------|------|
| 内存排序 | 数据量 < `sort_buffer_size` | 占用内存，CPU 排序 |
| **磁盘排序** | 数据量 > `sort_buffer_size` | **写临时文件，I/O 暴涨** |

20 万行数据很可能超过默认 `sort_buffer_size`（256KB~1MB），触发磁盘排序：

```sql
-- 查看 sort_buffer_size
SHOW VARIABLES LIKE 'sort_buffer_size';
-- 默认 262144 (256KB)，20 万行远超此值
```

量化浪费：

```
实际需要: 10 行（最新 10 条消息）
实际扫描: 198,624 行（全表）
实际排序: 198,624 行（全部排序）
浪费比例: 99.995%
```

::: warning filesort 的隐性风险
- 内存不足时落盘，产生大量临时文件 I/O
- 大表 ORDER BY 可能耗时数秒甚至超时
- 高并发时多个 filesort 同时占用 sort_buffer，内存压力大
:::

::: tip 核心认知
无索引的 ORDER BY + LIMIT 需要全表扫描后 filesort 排序再取前 N。给排序字段建索引后，B+ 树天然有序，只需扫描 N 个叶子节点即可。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 加索引 idx_created (created_at) 后，B+ 树有序直接取前 10 条
-- 需先执行 setup-good.sql 建立索引
SELECT id, user_id, content, created_at
FROM t_message
ORDER BY created_at DESC
LIMIT 10;
```

先执行 setup-good.sql 建立索引：

```sql
-- setup-good.sql: 给 created_at 建索引，ORDER BY 利用索引有序性
ALTER TABLE t_message ADD KEY idx_created (created_at);
```

### 原理

`idx_created (created_at)` 是 B+ 树索引，天然按 created_at 有序存储：

1. **索引有序**：DESC 只需从索引末尾（最大值）反向扫描
2. **只取 N 条**：扫描索引最右端 10 个叶子节点即可，无需全表
3. **回表 10 次**：取到 10 个主键后回表读取完整行数据
4. **无 filesort**：索引本身有序，无需额外排序

执行流程（优化后）：

```
1. 定位 idx_created 索引最右端（最大 created_at）
2. 反向扫描索引，取 10 个叶子节点（10 个主键 id）
3. 用这 10 个 id 回表读取完整行
4. 返回结果
（无全表扫描、无 filesort）
```

进阶优化--若查询只需索引列，可避免回表：

```sql
-- 只查 created_at（覆盖索引，无需回表）
SELECT created_at FROM t_message ORDER BY created_at DESC LIMIT 10;
-- Extra: Using index（覆盖索引，最快）
```

若需多列，可建联合索引：

```sql
-- 常见模式: 按用户取最新消息
ALTER TABLE t_message ADD KEY idx_user_created (user_id, created_at);
SELECT * FROM t_message WHERE user_id = 12345 ORDER BY created_at DESC LIMIT 10;
-- 用 idx_user_created 定位到该用户，再按 created_at 倒序取 10 条
```

### 对比

| | bad.sql (无索引) | good.sql (有索引) |
|---|---|---|
| type | ALL | index |
| rows | ~198,624 | 10 |
| Extra | Using filesort | NULL |
| 回表次数 | 0（直接读全表） | 10 |
| 耗时 | ~150 ms | ~1 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '198,624', Extra: 'Using filesort' }"
  :good="{ type: 'index', key: 'idx_created', rows: '10', Extra: 'NULL（filesort 消失）' }"
  improvement="全表扫描变索引扫描，扫描行从 20 万降到 10，消除 filesort，耗时下降约 150 倍"
/>

## 避坑指南

::: warning 注意事项

1. **排序字段必须建索引**。ORDER BY 的列建索引是消除 filesort 的根本手段。没有索引，优化器只能全表扫描后排序，LIMIT 再小也救不了。

2. **WHERE + ORDER BY 要建联合索引**。如果查询是 `WHERE user_id = ? ORDER BY created_at DESC LIMIT 10`，单独给 `created_at` 建索引没用（WHERE 过滤后数据无序）。需要建 `(user_id, created_at)` 联合索引，先定位用户再按时间有序。

3. **方向不一致也会 filesort**。索引默认 ASC，`ORDER BY created_at ASC` 能正向扫描，`ORDER BY created_at DESC` 在 8.0 中也能反向扫描（无需专门建降序索引）。但联合索引 `(user_id, created_at ASC)` 配合 `ORDER BY created_at DESC` 仍可能 filesort，此时考虑降序索引 `(user_id, created_at DESC)`。

4. **LIMIT 不是免死金牌**。很多人以为加了 LIMIT 就不会慢，实际上无索引时 filesort 是先排序再取前 N，LIMIT 不能减少排序的数据量。索引才是正解。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 排序字段建索引消除 filesort | ✅ 支持 | ✅ 支持 |
| `ORDER BY DESC` 反向扫描索引 | ✅ 支持（升序索引反向扫） | ✅ 支持 |
| 降序索引 `DESC` | ❌ 忽略，仍按 ASC | ✅ 真正支持 |
| 覆盖索引 `Using index` | ✅ 支持 | ✅ 支持 |

::: tip ORDER BY + LIMIT 索引设计原则
1. **排序字段建索引**：ORDER BY 的列建索引，利用 B+ 树有序性
2. **方向一致**：索引默认 ASC，ORDER BY DESC 也能反向扫描（无需专门建 DESC 索引，8.0 支持降序索引）
3. **配合 WHERE**：若 WHERE + ORDER BY 同时存在，建 (过滤列, 排序列) 联合索引
4. **LIMIT 越小收益越大**：LIMIT 10 时索引只扫 10 行，全表则扫全部
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 27-orderby-limit-no-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 27-orderby-limit-no-index --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 27-orderby-limit-no-index --no-seed
```
