# UNION vs UNION ALL

<CaseMeta difficulty="⭐" category="查询改写" versions="5.7 & 8.0" :tags="['UNION', 'UNION ALL', '去重', '临时表']" />

## 候两个查询结果根本没有重复行
合并两个数据源的查询结果时，开发者习惯性写了 `UNION`--毕竟"合并"听起来就该去重。但 `UNION` 会对合并后的结果集自动去重，需要创建临时表并排序去重，开销不小。而很多时候两个查询结果根本没有重复行，去重操作纯属浪费。

```sql
-- 两表数据天然无重复，UNION 的去重纯属浪费
SELECT code, name FROM t_source_a
UNION
SELECT code, name FROM t_source_b;
```

本案例中两表 code 前缀不同（A 表 `A00001`、B 表 `B00001`），天然无重复。但 `UNION` 仍然创建临时表，把 20 万行逐行插入并做唯一键去重检查，耗时约 120ms。改用 `UNION ALL` 后无需去重，直接拼接结果，耗时降至约 50ms，`Using temporary` 消失。

::: warning 真实场景
合并分表查询、跨数据源汇总、多条件 OR 改写为 UNION--这些场景随处可见。很多开发者分不清 UNION 和 UNION ALL 的区别，默认用 UNION"以防万一"，却不知道每次都在付出临时表去重的代价。数据量大了或高频调用时，这成了隐蔽的性能浪费。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: UNION 自动去重，需创建临时表并排序去重
-- 两表数据天然无重复，去重操作纯属浪费
SELECT code, name FROM t_source_a
UNION
SELECT code, name FROM t_source_b;
```

### EXPLAIN 结果

```
+----+--------------+-------------+-------+---------------+----------+---------+------+--------+----------+----------------+
| id | select_type  | table       | type  | possible_keys | key      | key_len | ref  | rows   | filtered | Extra          |
+----+--------------+-------------+-------+---------------+----------+---------+------+--------+----------+----------------+
|  1 | PRIMARY      | t_source_a  | index | NULL          | idx_code | 82      | NULL |  99812 |   100.00 | Using index    |
|  2 | UNION        | t_source_b  | index | NULL          | idx_code | 82      | NULL |  99812 |   100.00 | Using index    |
| NULL | UNION RESULT| <union1,2> | ALL   | NULL          | NULL     | NULL    | NULL |   NULL |   NULL   | Using temporary|
+----+--------------+-------------+-------+---------------+----------+---------+------+--------+----------+----------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | `PRIMARY` / `UNION` / `UNION RESULT` | 三个阶段：A 查询 + B 查询 + 合并结果 |
| table A/B type | `index` | 全索引扫描（覆盖索引 idx_code） |
| 最后一行 Extra | **`Using temporary`** | **创建临时表做去重！** |

### 为什么慢

`UNION`（不带 ALL）会自动对合并后的结果集去重：

1. **临时表**：MySQL 创建一张临时表，对 `(code, name)` 建立唯一键约束
2. **逐行插入去重**：A 表 10 万行 + B 表 10 万行 = 20 万行，全部插入临时表
3. **唯一键检测**：每行插入时检查是否已存在，存在则丢弃
4. **可能落盘**：20 万行临时表可能超过 `tmp_table_size`，转为磁盘临时表

执行流程：

```
1. 扫描 t_source_a 的 idx_code 索引（10 万行）
2. 扫描 t_source_b 的 idx_code 索引（10 万行）
3. 创建临时表（含 code, name 唯一键）
4. 将 20 万行逐行插入临时表（去重）
5. 从临时表读取最终结果
```

本案例两表 code 前缀不同（A 表 `A00001`、B 表 `B00001`），**天然无重复**。UNION 的去重操作完全多余，白白付出临时表的开销。

::: warning UNION 去重代价
- 临时表创建与写入：内存/磁盘 I/O
- 唯一键去重检查：每行一次哈希/比较
- 结果集大时可能落盘，性能骤降
- 若无重复需求，永远优先 UNION ALL
:::

::: tip 核心认知
UNION = UNION ALL + 去重（临时表）。确认结果无重复时用 UNION ALL，避免不必要的临时表去重开销。
:::

## 优化方案

### good.sql

```sql
-- good.sql: UNION ALL 不去重，直接拼接结果，更快
-- 已知两表 code 前缀不同（A/B），无重复行
SELECT code, name FROM t_source_a
UNION ALL
SELECT code, name FROM t_source_b;
```

### 原理

`UNION ALL` 不去重，直接拼接两个查询结果：

1. **无临时表**：不创建临时表，不写入去重
2. **无唯一键检查**：直接输出 A 表结果 + B 表结果
3. **流式输出**：A 表扫完即可输出，B 表扫完追加，无需等待全部完成

执行流程（优化后）：

```
1. 扫描 t_source_a 的 idx_code 索引（10 万行）-> 直接输出
2. 扫描 t_source_b 的 idx_code 索引（10 万行）-> 直接输出
（无临时表、无去重）
```

决策表：

| 场景 | 选择 | 原因 |
|------|------|------|
| 两结果集确定无重复 | **UNION ALL** | 避免去重开销 |
| 两结果集可能有重复 | UNION | 需要去重 |
| 需要去重但可接受业务层处理 | UNION ALL + 业务去重 | 数据库更轻量 |
| 单表查询用 UNION 拆分条件 | **UNION ALL** | 同表不可能自相重复 |

### 对比

| | bad.sql (UNION) | good.sql (UNION ALL) |
|---|---|---|
| 临时表 | Using temporary | 无 |
| 去重检查 | 20 万次 | 0 |
| 结果行数 | 20 万（无重复） | 20 万（无重复） |
| 耗时 | ~120 ms | ~50 ms |

<ExplainCompare
  :bad="{ type: 'index + UNION RESULT', key: 'idx_code', rows: '99,812 + 99,812', Extra: 'Using temporary' }"
  :good="{ type: 'index', key: 'idx_code', rows: '99,812 + 99,812', Extra: 'Using index（无临时表）' }"
  improvement="消除临时表去重，省去 20 万次去重检查，耗时下降约 2.4 倍"
/>

## 避坑指南

::: warning 注意事项

1. **默认用 UNION ALL**。只有明确需要去重且无法在数据层保证无重复时才用 UNION。这是最简单也最容易被忽视的优化--一个关键字的差别。

2. **确认无重复后再改**。改用 UNION ALL 前要确认两个查询结果确实无重复。本案例通过 code 前缀不同（A/B）来保证。如果不确定，可以先跑一次 `SELECT COUNT(*) - COUNT(DISTINCT ...)` 检查是否有重复行。

3. **单表拆分条件的 UNION 一定用 ALL**。将 `WHERE a OR b` 改写为 `WHERE a UNION ALL WHERE b` 时，同一张表不可能出现重复行（每行只满足一个条件或被两个子查询各取一次但主键不同），用 UNION ALL 即可。

4. **临时表落盘是性能杀手**。UNION 的临时表超过 `tmp_table_size` 或 `max_heap_table_size` 时会转为磁盘临时表，性能骤降。大数据量 UNION 更要用 UNION ALL。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| UNION 去重（临时表） | ✅ Using temporary | ✅ Using temporary |
| UNION ALL 不去重 | ✅ 无临时表 | ✅ 无临时表 |
| 临时表引擎 | MEMORY / MyISAM | MEMORY / TempTable（8.0 新引擎） |
| 8.0 临时表改进 | - | TempTable 引擎 + `temptable_max_ram` 控制 |

::: tip 经验法则
**默认用 UNION ALL**，只有明确需要去重且无法在数据层保证无重复时才用 UNION。很多业务场景下，两表数据天然不交叉（如本案例 A/B 前缀），UNION 的去重纯属浪费。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 26-union-vs-union-all

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 26-union-vs-union-all --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 26-union-vs-union-all --no-seed
```
