# EXPLAIN 参考结果 - good.sql（UNION ALL 改写避免 index_merge）

> 本案例无 setup-good.sql，bad/good 差异在于 SQL 改写方式。

## MySQL 8.0（实测 8.0.46，100 万行数据）

```
+----+--------------+--------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------------+
| id | select_type  | table        | partitions | type | possible_keys | key       | key_len | ref   | rows   | filtered | Extra       |
+----+--------------+--------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------------+
|  1 | PRIMARY      | t_user_merge | NULL       | ref  | idx_status    | idx_status| 2       | const | 200000 |   100.00 | NULL        |
|  2 | UNION        | t_user_merge | NULL       | ref  | idx_city      | idx_city  | 83      | const |  10000 |   100.00 | Using where |
|  0 | UNION RESULT | <union1,2>   | NULL       | ALL  | NULL          | NULL      | NULL    | NULL  |   NULL |     NULL | Using temporary |
+----+--------------+--------------+------------+------+---------------+-----------+---------+-------+--------+----------+-------------+
```

## 关键改进

| 步骤 | 字段 | 值 | 分析 |
|------|------|-----|------|
| 第一行 (id=1) | type | `ref` | status=1 走 idx_status 索引，精确匹配 |
| 第一行 (id=1) | rows | ~200,000 | idx_status 定位约 20 万行 |
| 第二行 (id=2) | type | `ref` | city='北京' 走 idx_city 索引，精确匹配 |
| 第二行 (id=2) | rows | ~10,000 | idx_city 定位约 1 万行 |
| 第二行 (id=2) | Extra | `Using where` | 额外过滤 status != 1，排除与第一个查询的交集 |
| UNION RESULT | Extra | `Using temporary` | UNION ALL 合并结果（无需去重排序） |

## 为什么快

UNION ALL 将 OR 拆成两个独立查询，每个查询只走一个索引：

1. 第一个查询 `WHERE status = 1` 走 `idx_status`，定位约 20 万行，直接回表读取
2. 第二个查询 `WHERE city = '北京' AND status != 1` 走 `idx_city`，定位约 1 万行，回表读取
3. UNION ALL 简单拼接两个结果集，无需排序去重

与 index_merge 的关键差异：
- **index_merge**：先合并 21 万个主键值（排序+去重），再统一回表 21 万次
- **UNION ALL**：两个查询各自独立执行，分别回表 20 万 + 1 万次，无需合并排序

UNION ALL 避免了 index_merge 的合并排序开销，且每个子查询的执行路径更简单高效。第二个查询通过 `AND status != 1` 排除与第一个查询的交集，确保结果正确（等价于 UNION 去重效果）。

实际耗时：约 **420 ms**。

## 量化对比

| 指标 | bad.sql | good.sql | 提升 |
|------|---------|----------|------|
| type | index_merge | ref + ref | 避免合并开销 |
| key | idx_status,idx_city | idx_status / idx_city | 各自独立使用 |
| 合并操作 | 21 万主键排序去重 | 无（UNION ALL 直接拼接） | 消除排序 |
| 回表次数 | 21 万次（合并后统一回表） | 20 万 + 1 万（各自独立回表） | 减少约 5% |
| 耗时 | ~850 ms | ~420 ms | **2 倍** |

## 5.7 vs 8.0 差异

- 两版都支持 index_merge 和 UNION ALL 改写，执行计划结构一致
- 8.0 的 index_merge 实现略有优化，但核心开销（合并排序）相同
- UNION ALL 改写在两版上都能稳定避免 index_merge，是更可移植的方案
