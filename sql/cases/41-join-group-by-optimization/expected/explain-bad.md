# EXPLAIN 参考结果 - bad.sql (先 JOIN 100万行再 GROUP BY)

## MySQL 8.0（实测 8.0.46，订单 100 万行 + 用户 1 万行）

```
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
| id | select_type | table | partitions | type   | possible_keys       | key                 | key_len | ref                     | rows   | filtered | Extra                        |
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
|  1 | SIMPLE      | u     | NULL       | index  | PRIMARY,idx_region  | idx_region          | 82      | NULL                    |  10000 |   100.00 | Using index                  |
|  1 | SIMPLE      | o     | NULL       | ref    | idx_user_id         | idx_user_id         | 8       | sql_treasure.u.id       |     98 |   100.00 | NULL                         |
+----+-------------+-------+------------+--------+---------------------+---------------------+---------+-------------------------+--------+----------+------------------------------+
```

（实际执行时 GROUP BY 阶段会产生 `Using temporary; Using filesort`）

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| u type | `index` | 用户表全索引扫描作为驱动表 |
| o type | `ref` | 订单表通过 idx_user_id 关联 |
| o rows | ~98 | 每用户平均 100 单（1万用户×100=100万） |
| JOIN 结果 | ~1,000,000 | **100 万行中间结果参与 GROUP BY** |
| GROUP BY Extra | `Using temporary; Using filesort` | 需要临时表 + 排序 |

## 为什么慢

执行流程：
1. 驱动表 t_user 全索引扫描 1 万行
2. 每行通过 idx_user_id 关联 t_order，平均每用户 100 单
3. **JOIN 产生 100 万行中间结果**
4. 对 100 万行按 `u.region` 做 GROUP BY
5. `Using temporary` -> 创建临时表存储 100 万行的聚合中间态
6. `Using filesort` -> 对最终 10 个地区结果排序

**核心问题**：GROUP BY 在 JOIN 之后执行，100 万行数据全部进入临时表参与聚合。当 `tmp_table_size` 不足时（默认 16MB），内存临时表溢出为磁盘临时表，性能下降一个数量级。

实际耗时：约 **2680 ms**（实测 MySQL 8.0.46，100 万行数据）。

## MySQL 5.7 差异

5.7 中行为一致，`Using temporary; Using filesort` 同样出现。5.7 临时表默认使用 MEMORY 引擎（含限制），溢出到磁盘时转换为 MyISAM；8.0 使用 TempTable 引擎（`temptable_engine`），磁盘溢出为 InnoDB。两版本在大数据量 GROUP BY 时性能差异不大。
