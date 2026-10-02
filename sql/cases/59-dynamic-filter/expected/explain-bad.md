# EXPLAIN 参考结果 - bad.sql (单列索引，多条件筛选)

## MySQL 8.0（20 万行数据）

```
+----+-------------+---------+------------+------+---------------------------+--------------+---------+-------+--------+----------+------------------------------------+
| id | select_type | table   | partitions | type | possible_keys             | key          | key_len | ref   | rows   | filtered | Extra                              |
+----+-------------+---------+------------+------+---------------------------+--------------+---------+-------+--------+----------+------------------------------------+
|  1 | SIMPLE      | t_goods | NULL       | ref  | idx_category,idx_status,  | idx_category | 4       | const |   4000 |    11.11 | Using index condition; Using where |
|    |             |         |            |      | idx_price                 |              |         |       |        |          | Using filesort                     |
+----+-------------+---------+------------+------+---------------------------+--------------+---------+-------+--------+----------+------------------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了 idx_category 等值定位 |
| possible_keys | 3 个单列索引 | 优化器有选择但只能用一个 |
| key | `idx_category` | 只选了 category_id 索引 |
| rows | ~4,000 | 预估 category_id=10 约 4000 行 |
| filtered | 11.11% | **回表后只有约 11% 满足条件** |
| Extra | `Using index condition; Using where; Using filesort` | 回表过滤 + 文件排序 |

## 为什么慢

三个条件 `category_id=10 AND status=1 AND price BETWEEN 100 AND 500`，但只有单列索引：

1. **优化器只能选一个索引**：选了 `idx_category`，定位到 category_id=10 的约 4000 行
2. **其余两个条件靠回表过滤**：这 4000 行全部回表到聚簇索引，读取 status 和 price 逐行判断
3. **filtered 仅 11.11%**：意味着约 89% 的回表是浪费的（不满足 status 和 price 条件）
4. **Using filesort**：ORDER BY sales 无索引支撑，需对筛选结果做文件排序
5. **无法利用索引消除无效行**：status 和 price 的过滤发生在回表之后

### 为什么不用 index_merge？

MySQL 有 index_merge 优化（合并多个单列索引），但有局限：
- index_merge 通常用于 OR 条件，AND 条件下优化器更倾向选一个最优索引
- 即使 merge，也需要对多个索引的结果取交集，开销不小
- 范围条件（price BETWEEN）的 merge 效率更低

实际耗时：约 **180 ms**（实测 MySQL 8.0.46，20 万行数据）。

## MySQL 5.7 差异

5.7 行为类似，优化器同样倾向选择单个单列索引。filtered 值可能略有不同。
index_merge 在 5.7 中支持但默认对 AND 条件不常触发。
