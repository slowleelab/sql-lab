# 降序索引消除 filesort

<CaseMeta difficulty="⭐⭐" category="优化器与8.0新特性" versions="5.7 & 8.0" :tags="['降序索引', 'filesort', '8.0新特性', 'ORDER BY']" />

## 场景痛点

事件日志系统按事件类型过滤后，需要按时间倒序取最近 20 条记录。查询本身很简单，但 EXPLAIN 结果里始终挂着 `Using filesort`，即使 `event_type` 和 `created_at` 上已经建了联合索引。

```sql
-- 取 LOGIN 事件最近 20 条
SELECT id, event_type, event_data, created_at
FROM t_event_log
WHERE event_type = 'LOGIN'
ORDER BY created_at DESC
LIMIT 20;
```

DBA 在 5.7 上尝试把索引改成 `(event_type, created_at DESC)`，结果 EXPLAIN 依然显示 `Using filesort`--写了 `DESC` 但根本没生效。20 万行数据下耗时约 180ms，虽然不算致命，但每秒几十次的高频查询累积起来，filesort 占用的 sort_buffer 和临时文件 I/O 让 CPU 和磁盘都吃紧。

::: warning 真实场景
任何"取最新 N 条"的查询都会踩到这个坑--最新消息、最近订单、最近登录记录。只要 `ORDER BY ... DESC` 配合升序索引，5.7 就无法消除 filesort，而开发者往往以为建了索引就万事大吉。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 仅有升序索引 idx_type_created (event_type, created_at)
-- ORDER BY created_at DESC 需要逆向扫描，5.7 不支持降序索引导致 filesort
-- （若已执行 setup-good.sql 添加了降序索引，请先重建表后再测试本 bad 场景）
SELECT id, event_type, event_data, created_at
FROM t_event_log
WHERE event_type = 'LOGIN'
ORDER BY created_at DESC
LIMIT 20;
```

### EXPLAIN 结果

```
+----+-------------+--------------+------+------------------+------------------+---------+-------+--------+----------+----------------+
| id | select_type | table        | type | possible_keys     | key              | key_len | ref   | rows   | filtered | Extra          |
+----+-------------+--------------+------+------------------+------------------+---------+-------+--------+----------+----------------+
|  1 | SIMPLE      | t_event_log  | ref  | idx_type_created | idx_type_created | 82      | const |  49812 |   100.00 | Using filesort |
+----+-------------+--------------+------+------------------+------------------+---------+-------+--------+----------+----------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 通过索引等值查找 event_type |
| key | `idx_type_created` | 用了联合索引 |
| rows | ~49,812 | event_type='LOGIN' 匹配约 5 万行 |
| Extra | **`Using filesort`** | **需要额外排序！** |

### 为什么慢

5.7 中 `idx_type_created (event_type, created_at)` 的 `created_at` 列实际按 **ASC 升序** 存储（5.7 会忽略建索引时写的 DESC 关键字）。

查询 `ORDER BY created_at DESC` 需要按时间倒序，而索引是正序的，优化器有两种选择：
1. 正向扫描索引再逆序输出（无法高效 LIMIT，需扫描全部匹配行）
2. 扫描匹配行后在内存/磁盘做 filesort 排序

两种方式都无法直接利用索引顺序 + LIMIT 提前终止，`Using filesort` 不可避免。

```
MySQL 执行流程:
1. 通过 idx_type_created 定位 event_type='LOGIN' 的行 -> 5 万行
2. 对这些行按 created_at DESC 做 filesort 排序
3. 排序完成后取前 20 行返回
（即使只需要 20 行，也要把 5 万行全部排序）
```

::: warning 5.7 的陷阱
5.7 允许在建索引时写 `created_at DESC`，但不报错且不生效，索引仍按 ASC 存储。这是最常见的"降序索引失效"误区。
:::

::: tip 核心认知
`ORDER BY DESC` 配合升序索引，优化器无法利用索引逆序扫描 + LIMIT 提前终止，只能 filesort 全部匹配行。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 建立降序索引 idx_type_created_desc (event_type, created_at DESC)
-- 需先执行 setup-good.sql 创建降序索引，8.0 真正按 DESC 存储索引，消除 filesort
SELECT id, event_type, event_data, created_at
FROM t_event_log
WHERE event_type = 'LOGIN'
ORDER BY created_at DESC
LIMIT 20;
```

先执行 setup-good.sql 创建降序索引：

```sql
-- setup-good.sql: 创建降序索引（8.0 真正支持 DESC 索引列）
-- 5.7 会忽略 DESC 关键字，仍按 ASC 存储
ALTER TABLE t_event_log ADD KEY idx_type_created_desc (event_type, created_at DESC);
```

### 原理

8.0 真正支持降序索引，`idx_type_created_desc (event_type, created_at DESC)` 中 `created_at` 列按 **DESC 倒序** 物理存储。

查询 `WHERE event_type = 'LOGIN' ORDER BY created_at DESC LIMIT 20` 时：
1. 索引按 `event_type` 等值定位
2. 在该范围内 `created_at` 已是倒序排列
3. **直接取前 20 行即可**，无需排序，无需扫描全部匹配行

虽然 `rows` 预估值仍显示 49812（统计信息估计值），但 LIMIT 配合有序索引可提前终止扫描，实际读取行数远小于估计值。

### 对比

| | bad.sql (升序索引) | good.sql (降序索引) |
|---|---|---|
| Extra | Using filesort | NULL |
| 实际扫描行 | ~49,812 | 20 |
| 耗时 | ~180 ms | ~2 ms |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_type_created', rows: '49,812', Extra: 'Using filesort' }"
  :good="{ type: 'ref', key: 'idx_type_created_desc', rows: '49,812 -> 20', Extra: 'NULL（filesort 消失）' }"
  improvement="消除 filesort，实际扫描行从 5 万降到 20，耗时下降 90 倍"
/>

## 避坑指南

::: warning 注意事项

1. **5.7 写 DESC 不报错但不生效**。建索引时写 `created_at DESC` 在 5.7 中被静默忽略，`SHOW INDEX` 仍显示 `A`（Ascending）。只有 8.0 才真正支持降序索引。

2. **不要盲目删除升序索引**。本案例保留了 `idx_type_created`，新增 `idx_type_created_desc`。如果有其他查询是 `ORDER BY created_at ASC`，升序索引仍有用。两个索引共存会增加写入开销，需根据实际查询模式取舍。

3. **降序索引的判定**。用 `SHOW INDEX FROM t_event_log` 查看 `Collation` 字段，8.0 中降序列显示 `D`（Descending），5.7 中即使写了 DESC 也显示 `A`。

4. **并非所有 ORDER BY DESC 都需要降序索引**。如果查询没有 LIMIT 或需要返回大部分匹配行，filesort 不可避免，降序索引收益有限。降序索引最适合 `ORDER BY DESC LIMIT N` 的高频查询。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 降序索引 `DESC` | ❌ 解析但忽略，仍按 ASC 存储 | ✅ 真正按 DESC 物理存储 |
| `SHOW INDEX` Collation | 始终显示 `A` | 降序列显示 `D` |
| `ORDER BY DESC LIMIT` + 升序索引 | Using filesort | Using filesort（需建降序索引才消除） |
| 降序索引消除 filesort | ❌ 不支持 | ✅ 索引逆序有序，直接取前 N |

::: tip 8.0 降序索引
如果你的查询是 `ORDER BY created_at DESC`，可以在 8.0 中创建降序索引：
```sql
KEY idx_type_created_desc (event_type, created_at DESC)
```
这样连 filesort 也能消除，LIMIT 只需扫描索引最前端的 N 行。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 72-descending-index

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 72-descending-index --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 72-descending-index --no-seed
```
