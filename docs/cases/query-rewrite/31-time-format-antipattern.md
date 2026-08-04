# 时间格式使用错误与最佳实践

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['时间格式', 'VARCHAR存时间', 'DATE_FORMAT', '范围查询', 'BETWEEN']" />

## 时间存成 VARCHAR：三种写法查询慢、数据对不上
订单表的 `created_at` 字段用 `VARCHAR(20)` 存时间字符串（如 `'2026-07-01 08:00:00'`）。运营后台要"查 2026-07-01 当天的订单"，开发写了三种写法，结果要么慢得离谱，要么数据对不上：

- 写法 A：`WHERE created_at >= '2026-07-01' AND created_at < '2026-07-02'` -- 看似能查，实际是字符串字典序比较，格式一不统一就出错。
- 写法 B：`WHERE DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01'` -- 为了"只比日期"套了函数，结果索引失效，20 万行全表扫描。
- 写法 C：`WHERE created_at BETWEEN '2026-07-01' AND '2026-07-01'` -- 以为 BETWEEN 两端写同一天就是"查当天"，结果漏掉当天几乎全部数据。

问题根源不在某一条 SQL 写法，而在**时间字段用 VARCHAR 存储**这个设计层面的反模式。字符串存时间会逼出各种修补写法（函数包裹、BETWEEN 补齐），每一步都藏着正确性或性能陷阱。

::: warning 真实场景
用 VARCHAR 存时间是新手和遗留系统里最常见的反模式。起因往往是"字符串存时间简单直观、可直接拼接显示"，但随着业务发展，范围查询、按天统计、时间运算需求一上来，字符串存的缺陷就全面暴露：比不动、排不对、函数一包就全表扫描、BETWEEN 一写就漏数据。正确做法是从源头用 DATETIME/TIMESTAMP 类型存储。
:::

## 问题分析

### bad 表结构

```sql
-- created_at 用 VARCHAR(20) 存储（反模式）
CREATE TABLE t_time_bad (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL,
    amount       DECIMAL(10,2) NOT NULL,
    created_at   VARCHAR(20)   NOT NULL,  -- '2026-07-01 08:00:00'
    PRIMARY KEY (id),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

20 万行数据，`created_at` 分布在近 1 年内，并额外插入了 2026-07-01 当天的固定数据（08:00:00、12:30:00、23:59:59）。

### 反模式 1: 字符串范围比较

```sql
-- bad.sql: VARCHAR 范围比较
SELECT * FROM t_time_bad
WHERE created_at >= '2026-07-01' AND created_at < '2026-07-02';
```

EXPLAIN：

```
type=range, key=idx_created, rows~547, Extra=Using index condition
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 走了索引范围扫描 |
| key | `idx_created` | VARCHAR 列索引被使用 |
| rows | ~547 | 预估扫描行数 |

**能走索引，但语义是"字符串字典序比较"而非"时间比较"**。当所有值严格遵循 `YYYY-MM-DD HH:MM:SS` 补零格式时，字典序恰好与时间序一致，表面查对了。但这是脆弱的巧合：

- 混入非补零格式（如 `2026-7-1 8:0:0`），字典序立刻错乱。
- 无法用时间函数（`DATEDIFF`、`DATE_ADD`、`YEAR()`）做日期运算，用了就要隐式转换或包裹函数，又回到反模式 2。
- 排序是字符串排序，格式不统一时 `ORDER BY created_at` 结果错误。
- 无数据校验：`'2026-13-45 99:99:99'` 这种非法时间也能存进去。

### 反模式 2: DATE_FORMAT 函数包裹字段致索引失效

```sql
-- bad.sql: 对 VARCHAR 列套用 DATE_FORMAT
SELECT * FROM t_time_bad
WHERE DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01';
```

EXPLAIN：

```
type=ALL, key=NULL, rows~199,687, Extra=Using where
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | **全表扫描** |
| possible_keys | `NULL` | DATE_FORMAT 函数导致优化器无法使用 idx_created |
| key | `NULL` | 索引完全未被使用 |
| rows | ~199,687 | 扫描全部近 20 万行 |
| Extra | `Using where` | 对每行计算 DATE_FORMAT 后再比较 |

`idx_created` 索引存储的是原始 VARCHAR 值，按 B+ 树字典序排列。`DATE_FORMAT(created_at, '%Y-%m-%d')` 对索引列施加了函数，破坏了索引的有序性，优化器无法直接定位入口，只能全表扫描逐行计算。实际耗时约 100ms+。

::: warning 与案例 04 的关系
本反模式与案例 04（函数操作致索引失效）原理相同，都是"函数包裹字段"破坏索引。区别在于视角：
- **案例 04**：`created_at` 是 `DATETIME`，用 `DATE()` / `DATE_FORMAT()` 包裹导致索引失效，重点是"函数致索引失效"这一通用陷阱。
- **本案例（案例 31）**：`created_at` 是 `VARCHAR`，开发者因为"存的是字符串"才不得不写 `DATE_FORMAT(col, '%Y-%m-%d')` 来取日期部分，重点是"格式选择错误（VARCHAR 存时间）逼出了函数包裹的写法"。根因是类型选错，治本应改用 DATETIME。
:::

### 反模式 3: BETWEEN 字符串日期的边界陷阱

```sql
-- bad.sql: BETWEEN 两端写同一天
SELECT * FROM t_time_bad
WHERE created_at BETWEEN '2026-07-01' AND '2026-07-01';
```

EXPLAIN：

```
type=range, key=idx_created, rows~1, Extra=Using index condition
```

走了索引，但**漏掉当天几乎全部数据**。`BETWEEN a AND b` 是闭区间 `[a, b]`，等价于 `>= a AND <= b`：

```
'2026-07-01 08:00:00' >= '2026-07-01'  ->  TRUE   (前缀匹配，更长字符串更大)
'2026-07-01 08:00:00' <= '2026-07-01'  ->  FALSE  (后面多了 ' 08:00:00'，更大)
```

`2026-07-01 08:00:00` 不满足 `<= '2026-07-01'`，**当天 00:00:00 之后的所有数据全部被漏掉**。只有字面量恰好等于 `'2026-07-01'`（没有时分秒部分）的行才命中，几乎查不到任何数据。

| 查询写法 | 命中行数 | 说明 |
|----------|----------|------|
| `BETWEEN '2026-07-01' AND '2026-07-01'` | **~0** | 漏掉当天几乎全部数据 |
| `BETWEEN '2026-07-01 00:00:00' AND '2026-07-01 23:59:59'` | 正常 | 补齐时分秒，但仍可能漏小数秒 |
| `>= '2026-07-01 00:00:00' AND < '2026-07-02 00:00:00'` | 正常 | **闭开区间，正解** |

::: warning BETWEEN 的边界本质
`BETWEEN a AND b` 在 MySQL 中是**闭区间** `[a, b]`，等价于 `>= a AND <= b`。对时间类型：
- `BETWEEN '2026-07-01' AND '2026-07-01'` 只覆盖"恰好等于 7-1 零点"的一个点，漏掉当天其余时刻。
- `BETWEEN '2026-07-01 00:00:00' AND '2026-07-01 23:59:59'` 看似覆盖全天，但若 DATETIME 有小数秒（`23:59:59.999999`），仍会漏掉最后一秒内的数据。
- **正解是闭开区间** `>= '2026-07-01 00:00:00' AND < '2026-07-02 00:00:00'`，按"天的起点"切分，无歧义、不重叠、不遗漏。
:::

## 优化方案

### good.sql

```sql
-- good.sql: DATETIME 类型 + 闭开区间范围查询
SELECT * FROM t_time_good
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
```

### 原理

`good` 表的 `created_at` 用 `DATETIME` 存储，正解从类型和写法两个层面修正反模式：

```
1. 类型: DATETIME 原生时间类型
   - 比较是真正的时间比较，不依赖字符串格式补零
   - 支持时间函数 (DATE/DATEDIFF/DATE_ADD/YEAR 等)，无需隐式转换
   - 排序按时间序，格式不影响排序正确性
   - 写入有数据校验，非法时间会报错

2. 写法: 闭开区间 [start, end)
   - created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00'
   - 精确覆盖"7-1 当天"，不漏 23:59:59，不算进 7-2 00:00:00
   - 按天的起点切分，连续多天不重叠不遗漏

3. 索引: 列保持原始形态，不包裹函数
   - idx_created 走 range 范围扫描
```

```
本案例查询 7-1 当天:
  -> created_at >= '2026-07-01 00:00:00'  (含当天起点)
  -> created_at <  '2026-07-02 00:00:00'  (不含次日起点)
  -> 区间 [7-1 00:00:00, 7-2 00:00:00) 精确等于"7-1 当天"
  -> 优化器在 B+ 树上做范围查找，走 idx_created range 扫描
```

### EXPLAIN（正解）

```
type=range, key=idx_created, key_len=5, rows~547, Extra=Using index condition
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 索引范围扫描 |
| key | `idx_created` | 索引被正确使用 |
| key_len | `5` | DATETIME（8.0 默认 5 字节，无小数秒） |
| rows | ~547 | 精确范围扫描 |
| Extra | `Using index condition` | 索引条件下推 |

### 为什么用闭开区间 [start, end) 而不是闭区间 [start, end]

- 闭开区间天然按"天的起点"切分，无需知道一天的结束时刻（`23:59:59`），也不会漏掉 `23:59:59.999999`（若 DATETIME 有小数秒）。
- `end = 次日 00:00:00` 是下一天的起点，`[今天起点, 明天起点)` 即"今天"，语义清晰。
- 连续多天查询不会重叠也不会遗漏：
  - 7-1：`[07-01 00:00, 07-02 00:00)`
  - 7-2：`[07-02 00:00, 07-03 00:00)`
  - `07-02 00:00:00` 严格属于 7-2，不与 7-1 重叠。

## 对比

### 三个反模式 vs 正解

| 方案 | 写法 | type | key | rows | 正确性 | 耗时(估) |
|------|------|------|-----|------|--------|----------|
| 反模式 1 | `VARCHAR >= '7-1' AND < '7-2'` | range | idx_created | ~547 | 脆弱(依赖格式) | ~1ms |
| 反模式 2 | `DATE_FORMAT(VARCHAR,...) = '7-1'` | **ALL** | NULL | ~199,687 | 正确 | ~100ms+ |
| 反模式 3 | `VARCHAR BETWEEN '7-1' AND '7-1'` | range | idx_created | ~1 | **错误(漏数据)** | ~1ms |
| **正解** | `DATETIME >= '7-1 00:00:00' AND < '7-2 00:00:00'` | **range** | idx_created | ~547 | **正确** | ~1ms |

核心结论：
- 反模式 2 性能最差（全表扫描 20 万行，比正解慢约 100 倍）。
- 反模式 3 正确性最差（漏掉当天几乎全部数据）。
- 反模式 1 看似性能与正解相当，但语义脆弱，格式不统一即出错。
- 正解在性能和正确性上都可靠：走索引范围扫描，时间比较语义正确，闭开区间无边界陷阱。

### VARCHAR 存时间 vs DATETIME 存时间 全维度

| 维度 | VARCHAR 存时间 | DATETIME 存时间 |
|------|----------------|-----------------|
| 比较语义 | 字符串字典序（依赖格式补零） | 时间比较（原生语义正确） |
| 时间函数 | 不可用或需隐式转换（致索引失效） | 原生支持（DATE/DATEDIFF/DATE_ADD 等） |
| 排序 | 字符串排序（格式不统一出错） | 时间排序（正确） |
| 索引范围扫描 | 可走但语义脆弱 | 可走且语义正确 |
| DATE_FORMAT/DATE 包裹 | 致索引失效(全表扫描) | 同样致索引失效(案例 04) |
| 数据校验 | 无（可存非法时间如 '13-45 99:99'） | 有（非法时间写入报错） |
| 存储空间 | VARCHAR(20) utf8mb4 最多 82 字节 | 5 字节(8.0)/8 字节(5.7) |
| BETWEEN 边界 | 易踩漏数据陷阱 | 仍建议用闭开区间，但语义清晰 |
| 小数秒支持 | 需更长字符串，易截断 | DATETIME(N) 原生支持 |
| 适用场景 | 不推荐存时间 | 业务时间字段首选 |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '199,687', Extra: 'Using where (DATE_FORMAT致索引失效)' }"
  :good="{ type: 'range', key: 'idx_created', rows: '547', Extra: 'Using index condition' }"
  improvement="DATETIME + 闭开区间范围查询：全表扫描 -> 索引范围扫描，扫描行数下降 99.7%，且消除字符串比较的语义脆弱性与 BETWEEN 边界漏数据陷阱"
/>

## 避坑指南

::: warning 时间格式常见陷阱

1. **不要用 VARCHAR 存时间**。字符串存时间会逼出各种修补写法（函数包裹、BETWEEN 补齐），每一步都藏着正确性或性能陷阱。时间字段一律用 `DATETIME`（业务时间）或 `TIMESTAMP`（事件绝对时刻）。

2. **范围查询用闭开区间 `[start, end)`**。`created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00'` 精确覆盖"当天"，无边界歧义、不重叠、不遗漏。避免 `BETWEEN`，尤其避免 `BETWEEN '日期' AND '同日期'` 这种漏数据写法。

3. **不要对时间列包裹函数**。`DATE_FORMAT(col, ...)`、`DATE(col)`、`YEAR(col)` 等会破坏索引有序性，致全表扫描。改写为范围查询：`YEAR(col)=2026` → `col >= '2026-01-01' AND col < '2027-01-01'`。

4. **BETWEEN 是闭区间，慎用于时间**。`BETWEEN a AND b` 等价于 `>= a AND <= b`。若必须用 BETWEEN 查当天，至少补齐 `BETWEEN '2026-07-01 00:00:00' AND '2026-07-01 23:59:59'`，但仍不如闭开区间健壮（小数秒仍可能漏）。

5. **格式不统一是 VARCHAR 存时间的隐形炸弹**。`'2026-7-1 8:0:0'` 与 `'2026-07-01 08:00:00'` 字典序不同，范围比较和排序都会出错。DATETIME 不存在此问题。

6. **VARCHAR 迁移到 DATETIME 要先清洗数据**。`ALTER TABLE ... MODIFY created_at DATETIME` 前，必须确认所有字符串都是合法且格式统一的时间，否则迁移会因非法值报错或截断。建议先 `SELECT created_at FROM t WHERE created_at REGEXP ...` 或 `STR_TO_DATE` 校验，清洗后再改类型。

:::

::: tip 本案例与案例 04、案例 30 的区别
三个案例都涉及时间字段，但角度不同，互补不重复：
- **案例 04（函数操作致索引失效）**：`created_at` 是 `DATETIME`，查询用 `DATE()` / `DATE_FORMAT()` 包裹列导致索引失效。重点是"函数包裹字段"这一通用索引陷阱，治标是改写为范围查询。
- **案例 30（时区与 TIMESTAMP vs DATETIME）**：`created_at` 用 `TIMESTAMP` 存 UTC，跨时区读出值随 session time_zone 变化，导致报表错位 8 小时。重点是"TIMESTAMP 的时区隐式转换"，治本是改用 DATETIME 存业务时间。
- **本案例（案例 31 时间格式使用错误）**：`created_at` 用 `VARCHAR` 存时间字符串，逼出 DATE_FORMAT 致索引失效、BETWEEN 漏数据、字符串比较语义脆弱三类问题。重点是"格式选择错误（VARCHAR 存时间）"这一设计层面反模式，治本是用 DATETIME 类型 + 闭开区间。

简言之：案例 04 治"函数陷阱"，案例 30 治"时区陷阱"，本案例（31）治"类型选错"。三者叠加才完整覆盖时间字段的常见踩坑面。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| DATETIME 范围扫描行为 | range，一致 | range，一致 |
| DATETIME 存储空间 | 8 字节（无小数秒） | **5 字节**（紧凑存储） |
| VARCHAR 索引行为 | 一致 | 一致 |
| DATE_FORMAT 致索引失效 | 一致 | 一致 |
| BETWEEN 闭区间语义 | 一致 | 一致 |
| VARCHAR 迁移到 DATETIME | 需先清洗数据 | 一致 |

::: tip 8.0 改进
8.0 对 DATETIME 做了紧凑存储优化：无小数秒时从 5.7 的 8 字节降到 5 字节。相比之下 VARCHAR(20) 在 utf8mb4 下占用更多空间。因此 8.0 下用 DATETIME 不仅语义正确，存储也更省，完全没有理由用 VARCHAR 存时间。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 31-time-format-antipattern

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 31-time-format-antipattern --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 31-time-format-antipattern --no-seed
```

::: tip 复现要点
本案例重点观察 `bad.sql` 三个反模式的 EXPLAIN 与结果差异：
- 反模式 1（VARCHAR 范围比较）：走 range 索引，但语义脆弱。
- 反模式 2（DATE_FORMAT 包裹）：`type=ALL` 全表扫描 20 万行，`key=NULL`。
- 反模式 3（BETWEEN 同日期）：走 range 但 `rows~1`，漏掉当天数据，对比正解的行数差异。
`good.sql` 用 DATETIME + 闭开区间，`type=range`、`key=idx_created`，结果正确。可在 `bad.sql` 末尾的 EXPLAIN 对比三条反模式执行计划。
:::
