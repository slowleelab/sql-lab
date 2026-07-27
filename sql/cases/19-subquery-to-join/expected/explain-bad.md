# EXPLAIN 参考结果 - bad.sql（IN 子查询查询"有订单的用户"）

## MySQL 8.0（5 万用户 + 20 万订单）

```
+----+-------------+-------------+------------+------+---------------+-------------+---------+---------------+-------+----------+-------------------------------------+
| id | select_type | table       | partitions | type | possible_keys | key         | key_len | ref           |  rows | filtered | Extra                               |
+----+-------------+-------------+------------+------+---------------+-------------+---------+---------------+-------+----------+-------------------------------------+
|  1 | SIMPLE      | t_user_sub  | NULL       | ALL  | PRIMARY       | NULL        | NULL    | NULL          | 50000 |   100.00 | NULL                                |
|  1 | SIMPLE      | t_order_sub | NULL       | ref  | idx_user_id   | idx_user_id | 8       | t_user_sub.id |     4 |   100.00 | Using index; FirstMatch(t_user_sub) |
+----+-------------+-------------+------------+------+---------------+-------------+---------+---------------+-------+----------+-------------------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | `SIMPLE` | 8.0 已将 IN 子查询优化为 semi-join（不再是 DEPENDENT SUBQUERY） |
| type (t_user_sub) | `ALL` | 外表全表扫描 5 万行，逐行驱动子查询探测 |
| key (t_user_sub) | `NULL` | 外表未走索引，需逐行遍历 |
| rows (t_user_sub) | ~50,000 | 全表扫描用户表 |
| Extra | `FirstMatch(t_user_sub)` | semi-join 的 FirstMatch 策略：每行用户匹配到第一个订单即跳过 |
| key (t_order_sub) | `idx_user_id` | 子查询走 idx_user_id 索引查找（覆盖索引，Using index） |

## 为什么慢

MySQL 8.0 的优化器虽然将 `IN` 子查询自动改写为 semi-join，避免了最坏情况下的相关子查询执行，但执行计划仍以 `t_user_sub` 为驱动表做**全表扫描**（`type=ALL`，5 万行）。对每个用户行，通过 `idx_user_id` 在订单表中探测是否存在匹配记录（`FirstMatch` 策略：命中一条即短路）。

问题在于驱动表选择不够高效：用户表 5 万行全扫，且 `SELECT *` 要求回表读取所有字段。虽然 FirstMatch 利用覆盖索引避免了对订单表的多余回表，但用户表的 5 万次全表扫描 + 回表代价无法避免。

在 MySQL 5.7 上情况可能更差：若优化器未能改写为 semi-join，`IN` 子查询会退化为**相关子查询**（`DEPENDENT SUBQUERY`），对用户表每一行都执行一次子查询扫描订单表，复杂度退化为 O(5 万 x 20 万)。

实际耗时：约 **180 ms**（实测 MySQL 8.0，5 万用户 + 20 万订单）。

## MySQL 5.7 差异

5.7 中此查询可能显示为 `select_type=DEPENDENT SUBQUERY`，即未触发 semi-join 优化，退化相关子查询逐行执行，性能显著劣于 8.0。8.0 的 semi-join 改写是该写法在 8.0 上"勉强可用"的原因，但仍不如显式 JOIN 高效可控。
