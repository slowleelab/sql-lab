# LIMIT 1 优化 EXISTS 子查询

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['EXISTS', 'COUNT', 'LIMIT 1', '子查询优化']" />

## 查"有未支付订单的用户"：EXISTS + LIMIT 1 更快
风控系统需要筛选出"有未支付订单的用户"，SQL 写成了这样：

```sql
SELECT * FROM t_user_exists u
WHERE (SELECT COUNT(*)
       FROM t_order_exists o
       WHERE o.user_id = u.id
         AND o.status = 0) > 0;
```

逻辑没问题，但性能很差。对每个用户都要执行一次 `COUNT(*)` 子查询，统计该用户所有未支付订单的数量。即使用户有 100 个未支付订单，也要全部 COUNT 出来——实际上只需要知道"是否存在"，不需要知道具体数量。

::: warning 真实场景
任何"判断是否存在"的场景都可能踩到这个坑。用 `COUNT(*) > 0` 判断存在性是最常见的反模式，应该改用 `EXISTS` 短路返回。
:::

## 问题分析

### bad.sql

```sql
SELECT *
FROM t_user_exists u
WHERE (SELECT COUNT(*)
       FROM t_order_exists o
       WHERE o.user_id = u.id
         AND o.status = 0) > 0;
```

### EXPLAIN 结果

```
+----+--------------------+-------+------------+------+--------------------+--------------------+---------+-------+--------+----------+-------------+
| id | select_type        | table | partitions | type | possible_keys      | key                | key_len | ref   | rows   | filtered | Extra       |
+----+--------------------+-------+------------+------+--------------------+--------------------+---------+-------+--------+----------+-------------+
|  1 | PRIMARY            | u     | NULL       | ALL  | NULL               | NULL               | NULL    | NULL  |  99876 |   100.00 | Using where |
|  2 | DEPENDENT SUBQUERY | o     | NULL       | ref  | idx_user_status    | idx_user_status    | 8       | u.id  |     10 |    25.00 | Using where |
+----+--------------------+-------+------------+------+--------------------+--------------------+---------+-------+--------+----------+-------------+
```

### 为什么慢

`WHERE (SELECT COUNT(*) ...) > 0` 的执行流程：

```
MySQL 执行流程:
1. 对用户表全表扫描 10 万行
2. 对每一行用户，执行一次 COUNT(*) 子查询：
   - 通过 idx_user_status 索引找到该用户的所有订单（平均约 10 个）
   - 统计其中 status = 0 的订单数量（平均约 2.5 个）
   - 返回 COUNT 结果
3. 判断 COUNT 结果是否 > 0
```

问题在于：即使用户有 100 个未支付订单，`COUNT(*)` 也要全部统计出来。实际上只需要知道"是否存在"（有没有至少 1 个），不需要知道具体数量。`COUNT(*)` 做了大量无用功。

10 万用户 × 平均 10 个订单 = **100 万次索引查找 + COUNT 计算**，耗时约 **320 ms**。

::: tip 核心认知
判断"是否存在"用 `EXISTS`，不要用 `COUNT(*) > 0`。`EXISTS` 找到第一行匹配记录就立即返回，无需扫描全部匹配行。`LIMIT 1` 进一步明确短路意图，帮助优化器选择最短执行路径。
:::

## 优化方案

### good.sql

```sql
SELECT *
FROM t_user_exists u
WHERE EXISTS (SELECT 1
              FROM t_order_exists o
              WHERE o.user_id = u.id
                AND o.status = 0
              LIMIT 1);
```

### 原理

`EXISTS` 的短路特性配合 `LIMIT 1`：

```
MySQL 执行流程:
1. 对用户表全表扫描 10 万行
2. 对每一行用户，执行一次 EXISTS 子查询：
   - 通过 idx_user_status 索引找到该用户的第一个 status = 0 的订单
   - 找到第一行就立即返回 TRUE，无需继续扫描
   - 如果找不到，返回 FALSE
3. EXISTS 为 TRUE 的用户行被保留
```

与 bad 方案的关键差异：
- **bad**：`COUNT(*)` 统计所有未支付订单数量，平均扫描 2.5 个订单
- **good**：`EXISTS + LIMIT 1` 找到第一个未支付订单就返回，平均扫描 1 个订单

`FirstMatch(u)` 表示 MySQL 使用 FirstMatch 策略：对每个用户，找到第一个匹配的订单就短路返回，不再继续扫描。`Using index` 表示覆盖索引扫描，无需回表。

虽然两者都是 `DEPENDENT SUBQUERY`，但 `EXISTS` 的短路特性大幅减少了子查询的执行时间。10 万用户 × 平均 1 个订单 = **10 万次索引查找**，耗时约 **95 ms**。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| 子查询类型 | COUNT(*) 全量统计 | EXISTS + LIMIT 1 短路 |
| 每用户扫描订单数 | ~2.5 个（全部未支付） | ~1 个（第一个未支付） |
| 子查询 rows | ~10 | ~1 |
| Extra | Using where | Using index; FirstMatch(u) |
| 总索引查找次数 | ~100 万次 | ~10 万次 |
| 耗时 | ~320 ms | ~95 ms |

<ExplainCompare
  :bad="{ type: 'ALL + DEPENDENT SUBQUERY', key: 'idx_user_status', rows: '99,876 × 10', Extra: 'Using where' }"
  :good="{ type: 'ALL + DEPENDENT SUBQUERY', key: 'idx_user_status', rows: '99,876 × 1', Extra: 'Using index; FirstMatch(u)' }"
  improvement="EXISTS 短路返回，索引查找次数减少 90%，耗时降低 70%"
/>

## 避坑指南

::: warning 注意事项

1. **判断存在性用 EXISTS，不要用 COUNT(*) > 0**。`EXISTS` 找到第一行就返回，`COUNT(*)` 要统计全部匹配行。对于"是否存在"的判断，`EXISTS` 的短路特性比 `COUNT(*)` 高效得多。

2. **LIMIT 1 进一步明确短路意图**。虽然 `EXISTS` 本身就有短路特性，但加上 `LIMIT 1` 可以帮助优化器选择最短执行路径，执行计划更稳定。

3. **EXISTS 子查询用 SELECT 1**。`EXISTS` 只判断存在性，不关心返回什么字段，用 `SELECT 1` 即可，不需要 `SELECT *`。

4. **确保子查询有索引**。本例中 `idx_user_status (user_id, status)` 是关键，没有索引的话 `EXISTS` 也会全表扫描。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| EXISTS 支持 | 支持 | 支持 |
| LIMIT 1 支持 | 支持 | 支持 |
| FirstMatch 优化 | 支持 | 更成熟 |
| 执行计划 | 一致 | 一致 |

::: tip 两版通用
`EXISTS + LIMIT 1` 是 5.7 和 8.0 通用的最佳实践。8.0 的 FirstMatch 优化更成熟，但 5.7 也能正确执行 EXISTS 短路。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 29-limit1-exists

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 29-limit1-exists --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 29-limit1-exists --no-seed
```
