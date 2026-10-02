# EXPLAIN 参考结果 - bad.sql（被驱动表无索引的灾难）

> 本案例 bad.sql 与 good.sql **SQL 完全相同**，差异在于是否执行了 `setup-good.sql`
> 为被驱动表 `t_order_item.order_id` 建索引。bad 即未建索引时的执行计划。

## MySQL 8.0（10 万行 t_order_main + 30 万行 t_order_item）

```
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+-------------------------------+
| id | select_type | table | partitions | type | possible_keys | key         | key_len | ref   |   rows | filtered | Extra                         |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+-------------------------------+
|  1 | SIMPLE      | o     | NULL       | ref  | idx_user_id   | idx_user_id |       8 | const |     10 |   100.00 | Using index                   |
|  1 | SIMPLE      | i     | NULL       | ALL  | NULL          | NULL        |    NULL | NULL  | 298892 |   100.00 | Using join buffer (hash join) |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+-------------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| 驱动表 `o` type | `ref` | 驱动表 `t_order_main` 通过 `idx_user_id` 索引定位 `user_id=5000`，只取少量行（约 10 行），`Using index` 表示覆盖索引 |
| 被驱动表 `i` type | `ALL` | 被驱动表 `t_order_item` 的 `order_id` 列**无索引**，退化为全表扫描 |
| 被驱动表 `i` key | `NULL` | 无可用索引，无法走 Index Nested Loop |
| 被驱动表 `i` rows | ~298,892 | 预估扫描约 30 万行（几乎整表） |
| Extra | `Using join buffer (hash join)` | 8.0 用 Hash Join 兜底：对驱动表结果建哈希表，再全表扫描被驱动表做探测 |

## 为什么慢

驱动表 `t_order_main` 通过 `idx_user_id` 过滤后只有约 10 行，本是个极佳的小结果集。但被驱动表 `t_order_item.order_id` 上没有索引，优化器**无法对每行驱动记录做一次 O(1) 的索引查找**（Index Nested Loop），只能退化为：

- **MySQL 8.0**：Hash Join。把驱动表那 10 行放进内存哈希表，然后**全表扫描 `t_order_item` 的约 30 万行**逐行探测哈希表。虽然复杂度从 BNL 的 O(n×m) 降到了 O(n+m)，但仍然要完整读一遍 30 万行表，I/O 与 CPU 开销都不小。
- **MySQL 5.7**：更糟，Block Nested Loop (BNL)。把驱动表分成块放入 join buffer，对每块都**全表扫描一次被驱动表**。当 join buffer 较小、驱动块数较多时，被驱动表会被反复全扫，放大效应明显。

根因是 **JOIN 列（被驱动表的 `order_id`）缺少索引**，导致无论哪个版本都无法走高效的索引嵌套循环连接。

## MySQL 5.7 差异

5.7 中被驱动表 `i` 的 Extra 显示 `Using join buffer (Block Nested Loop)`，而非 `hash join`。5.7 不支持 Hash Join，无索引 JOIN 只能 BNL，被驱动表被重复全表扫描，性能比 8.0 更差。

```
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+---------------------------------------+
| id | select_type | table | partitions | type | possible_keys | key         | key_len | ref   |   rows | filtered | Extra                                 |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+---------------------------------------+
|  1 | SIMPLE      | o     | NULL       | ref  | idx_user_id   | idx_user_id |       8 | const |     10 |   100.00 | Using index                           |
|  1 | SIMPLE      | i     | NULL       | ALL  | NULL          | NULL        |    NULL | NULL  | 298892 |   100.00 | Using join buffer (Block Nested Loop) |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+--------+----------+---------------------------------------+
```
