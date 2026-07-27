# 协处理器下推优化

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['coprocessor', '下推', 'tikv', '数据传输']" />

## 场景痛点

TiDB 查询变慢，表象是索引没利用好，但实际症结往往在于**SELECT 的 WHERE 条件能否下推到 TiKV 协处理器执行**。下推失败时，几十万行数据全量从 TiKV 传输到 TiDB Server 再过滤，大量时间消耗在网络上。

```sql
-- 看起来普通的查询，实际慢如蜗牛
SELECT * FROM t_pushdown WHERE LOWER(city) = 'beijing';
-- SELECT * FROM t_pushdown WHERE YEAR(created_at) = 2025;
```

::: danger 真实场景
开发者习惯用 MySQL 的写法，对字段套 `LOWER()`、`YEAR()` 等函数，在单机 MySQL 上完全没问题。但 TiDB 是分布式架构，计算分布在 TiDB Server 和 TiKV 两层，函数包裹会导致条件无法下推到 TiKV，数据必须全量网络传输。**20 万行数据的全表扫描可能比 MySQL 单机慢好几倍**。
:::

::: warning 核心认知
TiDB 的 EXPLAIN 输出中，`task` 列揭示了数据在哪一层处理：

- **`task=cop[tikv]`**：计算下推到 TiKV 协处理器，数据在 TiKV 本地过滤，只返回结果行
- **`task=root`**：计算在 TiDB Server 层执行，意味着数据必须先通过网络从 TiKV 传输到 TiDB

当 EXPLAIN 中看到 `Selection` 算子的 `task=root` 而 `TableFullScan` 的 `estRows` 又很大时，就要警惕了——这说明全量数据正在跨网络传输。
:::

## 问题分析

### bad.sql（下推失败）

```sql
-- 场景1: 函数包裹字段导致下推失败
EXPLAIN SELECT * FROM t_pushdown WHERE LOWER(city) = 'beijing';

-- 场景2: 日期函数下推失败
EXPLAIN SELECT * FROM t_pushdown WHERE YEAR(created_at) = 2025;

-- 场景3: TEXT 字段 LIKE 通配符限制下推
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio LIKE '%keyword%';
```

### EXPLAIN 结果（bad.sql 场景1）

```
+---------------------------+----------+-----------+---------------+------------------------------------+
| id                        | estRows  | task      | access object | operator info                      |
+---------------------------+----------+-----------+---------------+------------------------------------+
| Selection_5               | 20000.00 | root      |               | eq(lower(t_pushdown.city), "beijing")|
| └─TableReader_7           | 200000.00| root      |               | data:TableFullScan_6               |
|   └─TableFullScan_6       | 200000.00| cop[tikv] | table:t_pushdown | keep order:false                 |
+---------------------------+----------+-----------+---------------+------------------------------------+
```

### 为什么慢

下推失败的 SQL 执行流程：

1. **TableFullScan_6（task=cop[tikv]）**：TiKV 执行全表扫描，读取 t_pushdown 全量 20 万行
2. **TableReader_7（task=root）**：20 万行完整数据（id、user_id、name、age、city、bio、score、created_at 全列）从 TiKV 通过网络传输到 TiDB Server
3. **Selection_5（task=root）**：TiDB Server 接收 20 万行后执行 `LOWER(city) = 'beijing'` 过滤，最终返回约 2 万行

**关键问题**：`Selection_5` 的 `task=root`，意味着过滤发生在 TiDB 层。TiKV 只负责"无脑"扫描和传输，不做任何条件过滤。20 万行中 90% 的数据（18 万行）在网络上白传了一趟。

### 为什么 LOWER() 不能下推

TiKV 协处理器只支持**白名单内的函数和表达式**。`LOWER()` 函数不在白名单中，TiKV 不认识它，因此 TiDB 优化器无法将包含 LOWER 的过滤条件推送给 TiKV 执行。同样，`YEAR()`、`ABS()`、`JSON_EXTRACT()` 等函数也都不在协处理器支持范围内。

## 优化方案

### good.sql（下推成功）

```sql
-- 正解1: 避免在 WHERE 中使用函数，让条件直接下推
EXPLAIN SELECT * FROM t_pushdown WHERE city = 'Beijing';

-- 正解2: 用范围条件替代函数
EXPLAIN SELECT * FROM t_pushdown WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';

-- 正解3: IS NOT NULL 可下推 + LIMIT 限制传输
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio IS NOT NULL LIMIT 100;
```

### 原理

TiDB 优化器的协处理器下推（Coprocessor Pushdown）机制：

1. 优化器分析 WHERE 条件中的表达式，判断是否在 TiKV 协处理器白名单内
2. 如果条件可以下推，则 `Selection` 算子的 task 标记为 `cop[tikv]`
3. TiKV 在扫描数据时就地执行过滤，只把匹配的行通过网络返回给 TiDB
4. 如果有索引可以利用（如 `city = 'Beijing'` 走 `idx_city`），TiKV 甚至可以跳过全表扫描，只读取匹配的索引行

#### 正解1 的执行流程

`city = 'Beijing'` 无函数包裹，且存在 idx_city 索引：

1. TiKV 通过 `IndexRangeScan` 扫描 idx_city 索引，只读取 city='Beijing' 的行
2. 过滤后的约 2 万行从 TiKV 返回给 TiDB
3. TiDB 汇总展示结果

**数据传输量**从 20 万行降到 2 万行，缩水 10 倍。

#### 正解2 的执行流程

`created_at >= '2025-01-01' AND created_at < '2026-01-01'` 是范围条件：

1. TiKV 全表扫描（无索引可用时），但 **Selection task=cop[tikv]**，在 TiKV 本地过滤
2. 只返回约 5.5 万行给 TiDB（而非 20 万行）
3. 虽然仍是全表扫描，但网络传输量减少了约 3.6 倍

### 对比

| | bad.sql（LOWER函数） | good.sql（直接匹配） |
|---|---|---|
| Selection task | **root**（TiDB 层过滤） | **cop[tikv]**（TiKV 层过滤） |
| 扫描方式 | TableFullScan 全表 | IndexRangeScan 索引范围 |
| 扫描行数 | 200,000 | 20,000 |
| 网络传输行数 | 200,000 | 20,000 |
| 利用索引 | 否 | idx_city |
| 预估耗时 | ~500 ms | ~50 ms |

<ExplainCompare
  :bad="{ task: 'root', type: 'TableFullScan', estRows: '200,000', Extra: '全表扫描 20 万行，在 TiDB 层过滤，全量网络传输' }"
  :good="{ task: 'cop[tikv]', type: 'IndexRangeScan on idx_city', estRows: '20,000', Extra: 'TiKV 本地过滤，仅传输 2 万行' }"
  improvement="网络传输减少 10 倍，利用索引扫描进一步减少扫描行数，总体提速 10 倍+"
/>

## 避坑指南

::: warning 注意事项

1. **不要在 WHERE 条件中对字段使用函数**。这是最核心的原则。`LOWER(col)`、`UPPER(col)`、`YEAR(col)`、`MONTH(col)` 等都会阻止下推。

2. **用范围条件替代日期函数**。TiDB 不会自动将 `YEAR(created_at) = 2025` 转换为范围条件，需要手动改写：
   ```sql
   -- 错误: 无法下推
   WHERE YEAR(created_at) = 2025

   -- 正确: 可下推
   WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01'
   ```

3. **检查 EXPLAIN 中的 task 列**。养成每次分析慢查询时看一眼 `task` 列的习惯：
   - `Selection` 的 `task=root` 而扫描行数又大 —— 危险信号
   - `Selection` 的 `task=cop[tikv]` —— 安全

4. **TEXT 类型的 LIKE 查询要特别注意**。`LIKE '%keyword%'` 前导通配符会导致无法下推。如果可以，考虑：
   - 使用全文索引（FULLTEXT）
   - 限制前缀匹配 `LIKE 'prefix%'`（可下推）
   - 应用层预处理关键词

5. **实在需要函数，用生成列 + 索引**：
   ```sql
   -- 添加生成列
   ALTER TABLE t_pushdown ADD COLUMN city_lower VARCHAR(20)
       GENERATED ALWAYS AS (LOWER(city)) VIRTUAL;
   -- 给生成列加索引
   CREATE INDEX idx_city_lower ON t_pushdown(city_lower);
   -- 查询时使用生成列
   SELECT * FROM t_pushdown WHERE city_lower = 'beijing';
   ```
   这样 `city_lower` 的值在写入时就已计算好，查询时直接走索引，无函数开销。

6. **使用 TiDB Dashboard 或 slow log 确认**。可以通过慢查询日志中的 `Coprocessor` 信息查看实际下推情况。
:::

## 下推规则速查表

### 常见条件表达式下推情况

| 表达式/写法 | 是否下推到 TiKV | 说明 |
|------------|:--:|------|
| `col = 常量` | ✅ | 最基础，无条件可下推 |
| `col > / < / >= / <= 常量` | ✅ | 范围条件 |
| `col BETWEEN a AND b` | ✅ | 等价于范围条件 |
| `col IN (v1, v2, v3)` | ✅ | 多值等值 |
| `col IS NULL` | ✅ | NULL 判断 |
| `col IS NOT NULL` | ✅ | NOT NULL 判断 |
| `col LIKE 'prefix%'` | ✅ | 前缀匹配（无前导通配） |
| `col1 = col2`（同表列比较） | ✅ | 同表内列比较 |
| `LOWER(col) = 'x'` | ❌ | 函数不在白名单 |
| `UPPER(col) = 'X'` | ❌ | 函数不在白名单 |
| `YEAR(col) = 2025` | ❌ | 日期提取函数 |
| `MONTH(col) = 6` | ❌ | 日期提取函数 |
| `DATE_FORMAT(col, ...) = ...` | ❌ | 日期格式化函数 |
| `ABS(col) > 10` | ❌ | 数学函数（部分版本可能支持） |
| `col LIKE '%suffix'` | ❌ | 前导通配符 |
| `col LIKE '%mid%'` | ❌ | 前导通配符 |
| `CAST(col AS CHAR)` | ❌ | 类型转换 |
| `JSON_EXTRACT(col, '$.key')` | ❌ | JSON 函数 |
| `col IN (子查询)` | ❌ | 子查询无法下推 |
| `col = ANY(子查询)` | ❌ | 子查询无法下推 |

### EXPLAIN task 列含义对照

| task 值 | 含义 | 执行位置 |
|---------|------|---------|
| `cop[tikv]` | 协处理器：TiKV | 数据在 TiKV 节点本地处理，结果返回 TiDB |
| `cop[tiflash]` | 协处理器：TiFlash | 数据在 TiFlash 节点本地处理 |
| `root` | TiDB SQL 层 | 数据必须先传输到 TiDB Server 再处理 |
| `MPP`（v5.0+） | MPP 引擎 | TiFlash 节点间并行分布式计算 |

### 协处理器支持的核心操作（部分白名单）

| 类别 | 支持的操作 |
|------|----------|
| 比较 | `=`、`!=`、`<`、`>`、`<=`、`>=`、`IS NULL`、`IS NOT NULL` |
| 范围 | `BETWEEN`、`IN` |
| 模糊 | `LIKE`（仅前缀匹配 `'prefix%'`，无前导通配） |
| 逻辑 | `AND`、`OR`、`NOT` |
| 算术 | `+`、`-`、`*`、`/`、`DIV`、`%`（MOD） |
| 控制流 | `IF`、`IFNULL`、`NULLIF`、`CASE WHEN`、`COALESCE` |
| 数学 | `ABS`（部分版本）、`CEIL`、`FLOOR`、`ROUND`（有限支持） |
| 类型转换 | 仅支持有限的隐式转换 |

::: tip 关于 5.7 vs 8.0 差异

本案例针对 TiDB，不适用 MySQL 5.7 vs 8.0 的版本对比。TiDB 的协处理器下推行为取决于 TiDB 版本和 TiKV 版本，与 MySQL 版本号无关。各版本 TiDB 对协处理器下推函数的支持范围在持续扩展，请查阅对应版本的官方文档。

可粗略参考：
- TiDB v4.x：基础比较、逻辑运算、常用数学函数
- TiDB v5.x：扩展了更多字符串函数和日期函数的下推支持
- TiDB v6.x+：持续扩大函数下推白名单（如部分 JSON 操作）

:::

## 本地复现

```bash
# 默认在 TiDB 上运行
./scripts/run-case.sh 82-coprocessor-pushdown --ver tidb

# 跳过造数据重跑
./scripts/run-case.sh 82-coprocessor-pushdown --ver tidb --no-seed
```
