# EXPLAIN 参考结果 - bad.sql（下推失败场景）

## TiDB v7.5.1（20 万行 t_pushdown + 5 万行 t_pushdown_2）

---

### 场景1: LOWER(city) 函数包裹导致无法下推

```sql
EXPLAIN SELECT * FROM t_pushdown WHERE LOWER(city) = 'beijing';
```

```
+---------------------------+----------+-----------+---------------+------------------------------------+
| id                        | estRows  | task      | access object | operator info                      |
+---------------------------+----------+-----------+---------------+------------------------------------+
| Selection_5               | 20000.00 | root      |               | eq(lower(t_pushdown.city), "beijing")|
| └─TableReader_7           | 200000.00| root      |               | data:TableFullScan_6               |
|   └─TableFullScan_6       | 200000.00| cop[tikv] | table:t_pushdown | keep order:false                 |
+---------------------------+----------+-----------+---------------+------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `Selection_5 → TableReader_7 → TableFullScan_6` | Selection 在 root(task) 执行，数据必须先拉到 TiDB |
| estRows | `200000.00` (TableFullScan) / `20000.00` (Selection) | TiKV 扫描全部 20 万行，TiDB 预估过滤后剩 2 万行 |
| task | `root + cop[tikv]` | **关键**：Selection 的 task=root，说明过滤在 TiDB 完成 |
| Selection 位置 | 在 TableReader 之上 | Selection 在 root 层，意味着 20 万行全量从 TiKV 传输到 TiDB |
| operator info | `eq(lower(t_pushdown.city), "beijing")` | TiKV 协处理器不支持 LOWER 函数，只能返回全量数据 |

#### 为什么下推失败

TiDB 协处理器只支持白名单内的函数和表达式。`LOWER()` 函数不在 TiKV 协处理器支持列表中。执行流程：

1. **TableFullScan_6（cop[tikv]）**：TiKV 扫描 t_pushdown 表全量 20 万行
2. **TableReader_7（root）**：20 万行数据通过网络从 TiKV 传输到 TiDB Server
3. **Selection_5（root）**：TiDB Server 对 20 万行执行 LOWER(city) = 'beijing' 过滤

**数据传输量**：20 万行完整数据（包括所有列：id、user_id、name、age、city、bio、score、created_at）

---

### 场景2: YEAR(created_at) 函数下推失败

```sql
EXPLAIN SELECT * FROM t_pushdown WHERE YEAR(created_at) = 2025;
```

```
+---------------------------+----------+-----------+---------------+---------------------------------------------+
| id                        | estRows  | task      | access object | operator info                               |
+---------------------------+----------+-----------+---------------+---------------------------------------------+
| Selection_5               | 16666.67 | root      |               | eq(year(t_pushdown.created_at), 2025)        |
| └─TableReader_7           | 200000.00| root      |               | data:TableFullScan_6                        |
|   └─TableFullScan_6       | 200000.00| cop[tikv] | table:t_pushdown | keep order:false                          |
+---------------------------+----------+-----------+---------------+---------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| Selection_5 task | `root` | **YEAR() 函数在 TiDB 层执行**，无法下推 |
| TableFullScan_6 estRows | `200000.00` | 全表扫描，20 万行全部经过网络 |
| 预估结果 | `16666.67` | 约 1/12 的数据（2025 年占 3 年范围约 1/12） |

#### 为什么会这样

TiDB 优化器无法将 `YEAR(created_at) = 2025` 自动转换为范围条件。TiKV 协处理器不认识 YEAR 函数，只能将全部数据交给 TiDB 处理。

---

### 场景3: TEXT 字段 LIKE 通配符查询

```sql
EXPLAIN SELECT id, user_id, bio FROM t_pushdown WHERE bio LIKE '%keyword%';
```

```
+---------------------------+----------+-----------+---------------+------------------------------------------+
| id                        | estRows  | task      | access object | operator info                            |
+---------------------------+----------+-----------+---------------+------------------------------------------+
| Selection_5               | 20000.00 | root      |               | like(t_pushdown.bio, "%keyword%", 92)     |
| └─TableReader_7           | 200000.00| root      |               | data:TableFullScan_6                     |
|   └─TableFullScan_6       | 200000.00| cop[tikv] | table:t_pushdown | keep order:false                       |
+---------------------------+----------+-----------+---------------+------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| Selection_5 task | `root` | **LIKE 过滤在 TiDB 层执行** |
| 为什么下推受限 | `%keyword%` 以通配符开头 | 无法利用索引，TEXT 类型的 LIKE 不支持 TiKV 下推 |
| 数据传输 | 全量 20 万行 | bio 是 TEXT 类型，数据量大，网络传输开销高 |

---

## 下推失败的共同特征

| 特征 | 表现 |
|------|------|
| EXPLAIN 中 Selection 的 task | **`root`**（在 TiDB Server 执行过滤） |
| TableFullScan 的 task | `cop[tikv]`（TiKV 只负责扫描，不过滤） |
| 数据流向 | TiKV 扫描全量数据 → 网络传输 → TiDB 过滤 |
| 性能瓶颈 | 网络传输 + TiDB 内存/CPU |
| 根因 | WHERE 条件在 TiKV 协处理器**白名单之外** |

## 常见的无法下推的表达式

| 表达式类型 | 示例 | 原因 |
|-----------|------|------|
| 函数包裹字段 | `WHERE LOWER(col) = 'x'` | 函数不在协处理器白名单内 |
| 日期函数 | `WHERE YEAR(col) = 2025` | TiKV 不支持 YEAR/MONTH/DAY 函数 |
| 数学函数 | `WHERE ABS(col) > 10` | 部分数学函数不支持 |
| TEXT LIKE 前导通配 | `WHERE text_col LIKE '%x%'` | TEXT 类型 + 前导通配符双重限制 |
| 复杂子查询 | `WHERE col IN (SELECT ...)` | 子查询结果在 TiDB 层关联 |
| JSON 函数 | `WHERE JSON_EXTRACT(col, '$.key') = 'x'` | TiKV 不处理 JSON 函数 |
| 用户自定义函数 | `WHERE my_func(col) = 1` | 协处理器仅支持内建函数子集 |
