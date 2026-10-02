# EXPLAIN 参考结果 - good.sql（UNION 改写 + 给 city 建索引）

> 需先执行 `setup-good.sql` 给 city 列建索引。

## MySQL 8.0（30 万行数据）

```
+----+--------------+------------+------------+------+---------------+-----------+---------+-------+-------+----------+-----------------+
| id | select_type  | table      | partitions | type | possible_keys | key       | key_len | ref   | rows  | filtered | Extra           |
+----+--------------+------------+------------+------+---------------+-----------+---------+-------+-------+----------+-----------------+
|  1 | PRIMARY      | t_user_or  | NULL       | ref  | idx_phone     | idx_phone | 45      | const |     2 |   100.00 | NULL            |
|  2 | UNION        | t_user_or  | NULL       | ref  | idx_city      | idx_city  | 83      | const | 37500 |   100.00 | NULL            |
|  0 | UNION RESULT | <union1,2> | NULL       | ALL  | NULL          | NULL      | NULL    | NULL  |  NULL |     NULL | Using temporary |
+----+--------------+------------+------------+------+---------------+-----------+---------+-------+-------+----------+-----------------+
```

## 关键改进

| 步骤 | 字段 | 值 | 分析 |
|------|------|-----|------|
| 第一行 (id=1) | type | `ref` | phone 走 idx_phone 索引，精确匹配 2 行 |
| 第一行 (id=1) | rows | `2` | idx_phone 定位 2 行 |
| 第二行 (id=2) | type | `ref` | city 走 idx_city 索引，匹配约 37,500 行 |
| 第二行 (id=2) | rows | `37,500` | idx_city 定位约 3.75 万行 |
| UNION RESULT | Extra | `Using temporary` | 使用临时表完成去重合并 |

## 为什么快

UNION 将 OR 拆成两个独立查询：
1. 第一个查询 `WHERE phone = '13800138000'` 走 idx_phone，定位 2 行
2. 第二个查询 `WHERE city = '北京'` 走 idx_city，定位约 37,500 行
3. UNION 使用临时表合并去重

两个子查询都走索引，无需全表扫描。总扫描行数从 30 万降至约 37,500，耗时约 15ms。

## 量化对比

| 指标 | bad.sql | good.sql | 提升 |
|------|---------|----------|------|
| type | ALL | ref + ref | 索引生效 |
| key | NULL | idx_phone / idx_city | 两个索引分别生效 |
| rows | ~299,687 | ~37,502 | 减少 87% |
| 耗时 | ~110 ms | ~15 ms | 7 倍 |
