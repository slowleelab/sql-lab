# EXPLAIN 参考结果 - good.sql（被驱动表加索引后走 Index Nested Loop）

> 本案例 bad.sql 与 good.sql **SQL 完全相同**。good 指执行了 `setup-good.sql`
> （`ALTER TABLE t_order_item ADD KEY idx_order_id (order_id);`）后的执行计划。
> 两版 MySQL（5.7/8.0）执行计划一致。

## MySQL 8.0（10 万行 t_order_main + 30 万行 t_order_item）

```
+----+-------------+-------+------------+------+---------------+--------------+---------+-----------+------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys | key          | key_len | ref       | rows | filtered | Extra       |
+----+-------------+-------+------------+------+---------------+--------------+---------+-----------+------+----------+-------------+
|  1 | SIMPLE      | o     | NULL       | ref  | idx_user_id   | idx_user_id  |       8 | const     |   10 |   100.00 | Using index |
|  1 | SIMPLE      | i     | NULL       | ref  | idx_order_id  | idx_order_id |       8 | test.o.id |    3 |   100.00 | NULL        |
+----+-------------+-------+------------+------+---------------+--------------+---------+-----------+------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| 被驱动表 `i` type | `ref` | 由 `ALL`（全表扫描）变为 `ref`（索引等值查找），走 Index Nested Loop Join |
| 被驱动表 `i` key | `idx_order_id` | 用上了新建的 `order_id` 索引 |
| 被驱动表 `i` ref | `test.o.id` | 用驱动表 `o.id` 的值在索引上做等值查找 |
| 被驱动表 `i` rows | ~3 | 由约 30 万行降至约 3 行，每行驱动记录只需做一次索引定位 |
| Extra | `NULL` | 不再有 `Using join buffer`，无需 Hash Join / BNL 兜底 |

## 为什么快

加了 `idx_order_id` 后，JOIN 走 **Index Nested Loop Join**：

1. 驱动表 `t_order_main` 经 `idx_user_id` 过滤后约 10 行（`Using index` 覆盖索引，不回表）
2. 对这 10 行的每一行，用 `o.id` 的值到被驱动表 `t_order_item` 的 `idx_order_id` 上做一次索引查找（`type=ref`），每次定位约 3 行明细
3. 被驱动表的访问成本从“全表扫描 30 万行”降到“10 次索引查找 × 约 3 行回表”，即约 30 次精确读取

Hash Join / BNL 必须**整表扫描被驱动表**，而 Index Nested Loop 只需**按需索引查找**，访问行数从约 30 万骤降到约 30，I/O 量相差 4 个数量级。

## 量化对比

| 指标 | bad.sql（无索引） | good.sql（有索引） | 提升 |
|------|---------|----------|------|
| 被驱动表访问方式 | 全表扫描（ALL） | 索引查找（ref） | 质变 |
| 被驱动表扫描行数 | ~298,892 | ~3（每行驱动记录） | **~10 万倍** |
| 被驱动表 JOIN 列 | 无可用索引 | `idx_order_id` | 新增索引 |
| 8.0 JOIN 算法 | Hash Join（全扫被驱动表） | Index Nested Loop | 索引嵌套 |
| 5.7 JOIN 算法 | Block Nested Loop（反复全扫） | Index Nested Loop | 索引嵌套 |
| Extra | `Using join buffer (...)` | `NULL` | 无 join buffer |

## 5.7 vs 8.0 差异

- 加索引后两版执行计划一致，都走 Index Nested Loop Join，性能相当
- 差异体现在 **bad 方案**上：8.0 的 Hash Join 比 5.7 的 BNL 快（O(n+m) vs O(n×m)），但两者都远不如加索引后的 Index Nested Loop
- 本案例的核心结论：**无索引时的 JOIN 算法优化（Hash Join）只是兜底，给 JOIN 列加索引才是根本解**
