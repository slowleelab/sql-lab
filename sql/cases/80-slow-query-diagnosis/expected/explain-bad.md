# EXPLAIN 参考结果 - bad.sql (优化前)

## MySQL 8.0（实测 8.0.46，50 万行数据）

本案例的重点不在"单条 SQL 怎么优化"，而在**如何从生产中把慢 SQL 找出来**。
下面 3 条慢 SQL 正是通过 `slow log` 采集 -> `pt-query-digest` 聚合指纹 -> `performance_schema` 实时统计，交叉验证后锁定的 TOP 3。三者合计占总耗时 85%。

### SQL 1：深分页 + 无可用索引（排名 #1，占总耗时 45%）

```
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
| id | select_type | table        | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra                       |
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
|  1 | SIMPLE      | t_order_diag | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 498512 |    10.00 | Using where; Using filesort |
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-----------------------------+
```

### SQL 2：有 idx_user 但需回表 + filesort（排名 #2，占总耗时 27%）

```
+----+-------------+--------------+------------+------+---------------+----------+---------+-------+------+----------+----------------+
| id | select_type | table        | partitions | type | possible_keys | key      | key_len | ref   | rows | filtered | Extra          |
+----+-------------+--------------+------------+------+---------------+----------+---------+-------+------+----------+----------------+
|  1 | SIMPLE      | t_order_diag | NULL       | ref  | idx_user      | idx_user | 8       | const |    5 |   100.00 | Using filesort |
+----+-------------+--------------+------------+------+---------------+----------+---------+-------+------+----------+----------------+
```

### SQL 3：函数致索引失效（排名 #3，占总耗时 13%）

```
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table        | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_order_diag | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 498512 |   100.00 | Using where |
+----+-------------+--------------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

## 关键问题

### SQL 1 关键字段

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | 全表扫描，无可用索引 |
| possible_keys | `NULL` | status 列没有索引，idx_user 帮不上 |
| key | `NULL` | 没走任何索引 |
| rows | ~498,512 | 预估扫描近 50 万行 |
| Extra | `Using where; Using filesort` | WHERE 过滤 + 额外排序 |

### SQL 2 关键字段

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了 idx_user 定位 user_id |
| key | `idx_user` | 用了 user_id 索引 |
| rows | ~5 | 该用户约 5 行，扫描行数没问题 |
| Extra | `Using filesort` | amount 无序，必须 filesort |

### SQL 3 关键字段

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | 全表扫描 |
| possible_keys | `NULL` | DATE(created_at) 让任何 created_at 索引都失效 |
| key | `NULL` | 没走索引 |
| rows | ~498,512 | 扫描近 50 万行逐行算 DATE() |

## 为什么慢

3 条 SQL 的慢因各异，但都是"通过诊断链路才发现"的典型问题：

**SQL 1（深分页三重暴击）**：
1. `WHERE status=1` 无单独索引 -> 全表扫描 50 万行
2. `ORDER BY created_at DESC` 无索引有序性 -> filesort
3. `LIMIT 100000, 20` 深分页 -> 扫描并丢弃前 10 万行，每行都付出扫描代价
4. 实际耗时：约 **820 ms**

**SQL 2（回表 + filesort，单条不慢但高频成灾）**：
1. `idx_user` 只有 user_id 一列，能定位到该用户约 5 行（type=ref，看着没问题）
2. 但 `ORDER BY amount DESC`：amount 不在索引里，必须把该用户所有行回表读出 amount
3. 回表后在内存中 filesort 排序
4. 单次约 **15 ms**，但 pt-query-digest 显示该 SQL 每秒被调用上百次，累计总耗时排第 2
5. 这是"单条不慢、高频成灾"的典型，只有聚合统计才能暴露

**SQL 3（函数致索引失效）**：
1. `DATE(created_at) = '...'` 对列套函数，即使建了 idx_created 也用不上
2. 全表扫描 50 万行，逐行调用 DATE() 函数
3. 实际耗时：约 **480 ms**

## 诊断链路的价值（本案例核心）

这 3 条 SQL 不是 DBA 凭经验猜出来的，而是**诊断工具揪出来的**：

```
生产 CPU 90%
   │
   ├─ slow log 采集（long_query_time=1）
   │     → 数万条慢日志，人眼无法看
   │
   ├─ pt-query-digest 聚合指纹
   │     → 把常量替换成 ?，按总耗时排序
   │     → TOP 3 占总耗时 85%，一眼锁定
   │
   ├─ performance_schema 实时统计
   │     → events_statements_summary_by_digest
   │     → 与 pt-query-digest 排名交叉验证
   │
   └─ EXPLAIN / EXPLAIN ANALYZE 验证
         → 逐条看 type/key/rows/Extra
         → 8.0 用 EXPLAIN ANALYZE 看实际行数与耗时
```

如果没有这套链路，DBA 只能看到"CPU 高"，却不知道优化哪条 SQL--可能改了半天一条无关的 SQL。**优化的第 0 步，是先找到该优化什么。**

## MySQL 5.7 差异

- 5.7 EXPLAIN 输出结构与 8.0 一致（无 `partitions` 列的细微差异除外）
- 5.7 不支持 `EXPLAIN ANALYZE`（8.0 独有），只能看预估值，无法看实际执行统计
- 5.7 performance_schema 默认可能未开启，需在 my.cnf 配置 `performance_schema=ON` 并重启
