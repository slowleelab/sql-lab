# EXPLAIN 参考结果 - good.sql（下推成功场景）

## TiDB v7.5.1（20 万行 t_pushdown + 5 万行 t_pushdown_2）

---

### 正解1: 直接字段匹配，下推成功

```sql
EXPLAIN SELECT * FROM t_pushdown WHERE city = 'Beijing';
```

```
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
| id                            | estRows  | task      | access object             | operator info                           |
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
| IndexLookUp_7                 | 20000.00 | root      |                           |                                         |
| ├─IndexRangeScan_5(Build)     | 20000.00 | cop[tikv] | table:t_pushdown, index:idx_city | range:["Beijing","Beijing"]      |
| └─TableRowIDScan_6(Probe)     | 20000.00 | cop[tikv] | table:t_pushdown          | keep order:false                        |
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| IndexRangeScan_5 task | **`cop[tikv]`** | **索引扫描在 TiKV 本地完成**，只扫描 city='Beijing' 的行 |
| IndexRangeScan_5 estRows | `20000.00` | 预估 2 万行匹配（10 个城市均匀分布，约 1/10） |
| access object | `index:idx_city` | 利用 idx_city 索引，精确定位 |
| operator info | `range:["Beijing","Beijing"]` | 单值范围扫描，TiKV 直接定位到目标行 |

#### 为什么下推成功

1. `city = 'Beijing'` 是简单的等值条件，没有函数包裹
2. TiKV 协处理器原生支持等值比较、范围比较
3. `idx_city` 索引让 TiKV 可以不扫描全表，只读取匹配的 2 万行
4. **数据流向**：TiKV 扫描 2 万行 → 仅返回 2 万行给 TiDB（而非全量 20 万行）

---

### 正解2: 范围条件替代函数，下推成功

```sql
EXPLAIN SELECT * FROM t_pushdown WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';
```

```
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
| id                            | estRows  | task      | access object             | operator info                           |
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
| TableReader_7                 | 54794.52 | root      |                           | data:Selection_6                        |
| └─Selection_6                 | 54794.52 | cop[tikv] |                           | ge(t_pushdown.created_at, 2025-01-01), lt(t_pushdown.created_at, 2026-01-01) |
|   └─TableFullScan_5           | 200000.00| cop[tikv] | table:t_pushdown          | keep order:false                        |
+-------------------------------+----------+-----------+---------------------------+-----------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| Selection_6 task | **`cop[tikv]`** | **关键区别**：Selection 的 task 是 cop[tikv]，表示过滤在 TiKV 完成 |
| Selection_6 estRows | `54794.52` | TiKV 过滤后只返回约 5.5 万行（约 1/3.65） |
| TableFullScan_5 estRows | `200000.00` | 虽然是全表扫描，但 Selection 在 TiKV 本地过滤 |

#### 与 bad.sql 场景2 的对比

| | bad.sql (YEAR函数) | good.sql (范围条件) |
|---|---|---|
| Selection task | **root**（TiDB 过滤） | **cop[tikv]**（TiKV 过滤） |
| 传输行数 | 全量 20 万行 | 约 5.5 万行 |
| 网络流量 | 全量 | 仅 1/3.65 |
| EXPLAIN 形态 | Selection 在 TableReader 之上 | Selection 在 TableReader 之下（包裹在 TiKV） |

---

### 正解3: IS NOT NULL 可下推 + LIMIT 减少数据量

```sql
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio IS NOT NULL LIMIT 100;
```

```
+---------------------------+----------+-----------+--------------------------+-----------------------------------------+
| id                        | estRows  | task      | access object            | operator info                           |
+---------------------------+----------+-----------+--------------------------+-----------------------------------------+
| Limit_8                   | 100.00   | root      |                          | offset:0, count:100                     |
| └─TableReader_17          | 100.00   | root      |                          | data:Limit_16                           |
|   └─Limit_16              | 100.00   | cop[tikv] |                          | offset:0, count:100                     |
|     └─Selection_15        | 100.00   | cop[tikv] |                          | not(isnull(t_pushdown.bio))             |
|       └─TableFullScan_14  | 200000.00| cop[tikv] | table:t_pushdown         | keep order:false                        |
+---------------------------+----------+-----------+--------------------------+-----------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| Selection_15 task | **`cop[tikv]`** | `IS NOT NULL` 可以下推到 TiKV |
| Limit_16 task | **`cop[tikv]`** | LIMIT 也下推到 TiKV，一旦凑够 100 行就停止扫描 |
| 优势 | 双重下推 | Selection + LIMIT 都在 TiKV，大幅减少传输 |

#### 优化效果分析

与 bad.sql 场景3 对比：

- bad.sql：`bio LIKE '%keyword%'` —— Selection task=root，20 万行全量传输
- good.sql：`bio IS NOT NULL LIMIT 100` —— Selection task=cop[tikv]，最多传输 100 行

---

## TiDB 下推成功的关键特征

| 特征 | 表现 |
|------|------|
| EXPLAIN 中 Selection 的 task | **`cop[tikv]`**（在 TiKV 协处理器执行过滤） |
| 数据过滤位置 | TiKV 本地完成，只返回匹配行 |
| 是否利用索引 | 索引可进一步减少扫描范围 |
| 性能收益 | 减少网络传输 + 减少 TiDB 内存/CPU 压力 |

## 下推规则速查表

| 表达式/条件 | 是否下推 | 说明 |
|------------|---------|------|
| `col = 常量` | ✅ 可下推 | 最基础的等值条件 |
| `col > / < / >= / <= 常量` | ✅ 可下推 | 范围条件 |
| `col BETWEEN a AND b` | ✅ 可下推 | 等价于范围条件 |
| `col IN (1,2,3)` | ✅ 可下推 | 等值列表 |
| `col IS NULL / IS NOT NULL` | ✅ 可下推 | NULL 判断 |
| `col LIKE 'prefix%'` | ✅ 可下推 | 前缀匹配（非前导通配） |
| `col1 = col2` | ✅ 可下推 | 同表列比较 |
| `LOWER(col) = 'x'` | ❌ 不可下推 | 函数不在协处理器白名单 |
| `YEAR(col) = 2025` | ❌ 不可下推 | 日期提取函数 |
| `col LIKE '%mid%'` | ❌ 不可下推 | 前导通配符 |
| `col LIKE '%suffix'` | ❌ 不可下推 | 前导通配符 |
| `ABS(col) > 10` | ❌ 不可下推 | 数学函数 |
| `CAST(col AS ...)` | ❌ 不可下推 | 类型转换 |
| `JSON_EXTRACT(col, ...)` | ❌ 不可下推 | JSON 函数 |
| `col IN (SELECT ...)` | ❌ 不可下推 | 子查询 |

## 协处理器支持的关键函数/操作符白名单（部分）

| 类别 | 支持的操作 |
|------|----------|
| 比较操作符 | `=`, `!=`, `<`, `>`, `<=`, `>=`, `IS NULL`, `IS NOT NULL`, `BETWEEN`, `IN`, `LIKE`（无前导通配） |
| 逻辑操作符 | `AND`, `OR`, `NOT` |
| 算术操作符 | `+`, `-`, `*`, `/` |
| 控制流函数 | `IF`, `CASE WHEN`, `IFNULL`, `COALESCE` |
| 数学函数 | `ABS`（部分版本）, `CEIL`, `FLOOR`, `ROUND` |
| 字符串函数 | 白名单有限，部分简单函数支持 |

### 优化策略总结

1. **避免对 WHERE 条件中的字段使用函数**，保持字段"裸露"
2. **用范围条件替代日期函数**：`WHERE col >= '2025-01-01' AND col < '2026-01-01'` 替代 `YEAR(col) = 2025`
3. **优先使用精确匹配**，避免前导通配符 LIKE
4. **通过 EXPLAIN 验证下推**：确认 Selection 的 task = cop[tikv]
5. **善用生成列 + 索引**：如必须用函数，可创建生成列并建索引
