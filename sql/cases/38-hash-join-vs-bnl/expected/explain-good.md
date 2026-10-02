# EXPLAIN 参考结果 - good.sql（加索引后走 Index Nested Loop）

> 本案例 bad.sql 与 good.sql **SQL 完全相同**。good 指执行了 `setup-good.sql`
> （`ALTER TABLE t_b ADD KEY idx_a_id (a_id);`）后的执行计划。
> 注意：`t_a.val` 仍无索引，驱动表部分不变；优化集中在 JOIN 部分。
> 两版 MySQL（5.7/8.0）执行计划一致。

## MySQL 8.0（5 万行 t_a + 10 万行 t_b）

```
+----+-------------+-------+------------+------+---------------+----------+---------+-----------+-------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys | key      | key_len | ref       |  rows | filtered | Extra       |
+----+-------------+-------+------------+------+---------------+----------+---------+-----------+-------+----------+-------------+
|  1 | SIMPLE      | a     | NULL       | ALL  | NULL          | NULL     |    NULL | NULL      | 49731 |     2.00 | Using where |
|  1 | SIMPLE      | b     | NULL       | ref  | idx_a_id      | idx_a_id |       4 | test.a.id |     2 |   100.00 | NULL        |
+----+-------------+-------+------------+------+---------------+----------+---------+-----------+-------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| 被驱动表 `b` type | `ref` | 由 `ALL`（全表扫描）变为 `ref`（索引等值查找），走 Index Nested Loop Join |
| 被驱动表 `b` key | `idx_a_id` | 用上了新建的 `a_id` 索引 |
| 被驱动表 `b` ref | `test.a.id` | 用驱动表 `a.id` 的值在索引上做等值查找 |
| 被驱动表 `b` rows | ~2 | 由约 10 万行降至约 2 行，每次索引查找只定位少量行 |
| Extra | `NULL` | 不再有 `Using join buffer`，无需 Hash Join / BNL |
| 驱动表 `a` | 不变 | `t_a.val` 仍无索引，仍全表扫描（filtered 2.00），但这部分无法用 JOIN 索引优化 |

## 为什么快

给 `t_b.a_id` 加索引后，JOIN 走 **Index Nested Loop Join**：

1. 驱动表 `t_a` 仍因 `val` 无索引而全表扫描约 5 万行，过滤出约 1000 行（`filtered 2.00`）——这部分不变。
2. 对这 1000 行的每一行，用 `a.id` 的值到被驱动表 `t_b` 的 `idx_a_id` 上做一次索引查找（`type=ref`），每次定位约 2 行。
3. 被驱动表的访问成本从“全表扫描 10 万行”降到“约 1000 次索引查找 × 约 2 行”，即约 2000 次精确读取。

三种 JOIN 路径对比：
- **5.7 BNL**：对驱动块反复全扫被驱动表，O(n×m)，最慢
- **8.0 Hash Join**：全扫被驱动表一遍建哈希探测，O(n+m)，比 BNL 快但仍是全表扫描
- **Index Nested Loop（加索引后）**：按需索引查找，O(驱动行数 × log 被驱动表)，最快

本案例的关键：Hash Join 只是 8.0 对“无索引 JOIN”的兜底优化，**真正消除全表扫描的是给被驱动表 JOIN 列加索引**。

## 量化对比

| 指标 | bad.sql（无索引） | good.sql（有 idx_a_id） | 提升 |
|------|---------|----------|------|
| 被驱动表访问方式 | 全表扫描（ALL） | 索引查找（ref） | 质变 |
| 被驱动表扫描行数 | ~99,511（整表） | ~2（每行驱动记录） | **~5 万倍** |
| JOIN 算法（8.0） | Hash Join（全扫被驱动表） | Index Nested Loop | 索引嵌套 |
| JOIN 算法（5.7） | BNL（反复全扫被驱动表） | Index Nested Loop | 索引嵌套 |
| Extra | `Using join buffer (...)` | `NULL` | 无 join buffer |
| 驱动表 `t_a` | 全表扫描（val 无索引） | 全表扫描（val 无索引） | 不变 |

## 5.7 vs 8.0 差异

- 加索引后两版执行计划一致，都走 Index Nested Loop Join，性能相当
- 差异体现在 **bad 方案**：8.0 Hash Join（O(n+m)）显著快于 5.7 BNL（O(n×m)），这是 8.0 对无索引 JOIN 的重要改进
- 但两者都远不如加索引：**Hash Join 是兜底，索引才是根本解**；若 `t_a.val` 也能加索引，驱动表的全表扫描也可一并消除
