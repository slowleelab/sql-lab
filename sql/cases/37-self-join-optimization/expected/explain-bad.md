# EXPLAIN 参考结果 - bad.sql (函数包裹索引列导致失效)

## MySQL 8.0（实测 8.0.46，10 万行员工数据）

```
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
| id | select_type | table | partitions | type | possible_keys       | key                 | key_len | ref   | rows   | filtered | Extra                                        |
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
|  1 | SIMPLE      | e1    | NULL       | ref  | idx_department      | idx_department      | 202     | const |   9968 |   100.00 | Using index condition; Using filesort        |
|  1 | SIMPLE      | e2    | NULL       | ALL  | PRIMARY             | NULL                | NULL    | NULL  |  99680 |   100.00 | Range checked for each record (index map: 0x1)|
+----+-------------+-------+------------+------+---------------------+---------------------+---------+-------+--------+----------+----------------------------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| e1 type | `ref` | 驱动表通过 idx_department 定位"技术部" |
| e1 Extra | `Using filesort` | ORDER BY 需要额外排序 |
| e2 type | `ALL` | **被驱动表全表扫描** |
| e2 key | `NULL` | **主键索引未被使用** |
| e2 rows | ~99,680 | 预估扫描约 10 万行 |
| e2 Extra | `Range checked for each record` | 每行重新评估索引，无法提前锁定索引 |

## 为什么慢

JOIN 条件 `IFNULL(e1.manager_id, 0) = e2.id` 对 `e1.manager_id` 施加了 `IFNULL()` 函数包裹。虽然 `e2.id` 是主键，但优化器无法将函数表达式与主键做等值匹配，只能对被驱动表 e2 逐行全表扫描。

实际行为：
1. 驱动表 e1 通过 `idx_department` 定位"技术部"约 1 万名员工
2. 对每个员工，执行 `IFNULL(manager_id, 0) = e2.id`
3. 由于函数包裹，e2 的主键索引无法被直接利用，显示 `Range checked for each record`
4. 每行关联都要在 e2 表上做一次范围检查，退化为接近全表扫描
5. 最终还需要 `Using filesort` 对结果排序

10 万行表上 1 万次驱动循环 × 10 万行扫描 = 约 1 亿次行检查。

实际耗时：约 **1250 ms**（实测 MySQL 8.0.46，10 万行数据）。

## MySQL 5.7 差异

5.7 中行为一致，`Range checked for each record` 同样出现，性能表现类似。5.7 和 8.0 都无法对函数包裹的索引列做索引匹配。
