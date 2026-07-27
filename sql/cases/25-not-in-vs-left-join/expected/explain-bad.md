# EXPLAIN 参考结果 - bad.sql (NOT IN 子查询)

## MySQL 8.0（实测 8.0.46，10 万用户 + 20 万订单）

```
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
| id | select_type | table         | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
|  1 | PRIMARY     | t_user_check  | ALL   | NULL          | NULL       | NULL    | NULL |  99812 |   100.00 | Using where |
|  2 | SUBQUERY    | t_order_check | index | NULL          | idx_user_id| 8       | NULL | 198624 |   100.00 | Using index |
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | PRIMARY + SUBQUERY | **子查询未被优化为半连接** |
| table 1 type | `ALL` | 用户表全表扫描 |
| table 2 type | `index` | 子查询扫描整个 idx_user_id 索引 |
| rows (subquery) | ~198,624 | 子查询物化 20 万行 user_id |

## 为什么慢

`NOT IN` 子查询的执行逻辑：

1. **子查询物化**：先执行 `SELECT user_id FROM t_order_check`，把 20 万个 user_id 收集到临时结构
2. **逐行匹配**：对 t_user_check 的每一行（10 万行），检查其 id 是否在子查询结果集中
3. **无法用索引短路**：NOT IN 是"否定"语义，优化器难以转化为高效的索引反连接

### NOT IN 的 NULL 陷阱

```sql
-- 若 t_order_check.user_id 含 NULL，NOT IN 永远返回空！
SELECT 1 WHERE 1 NOT IN (2, 3, NULL);  -- 结果: 空（NULL 导致整个表达式为 NULL）
```

NOT IN 对 NULL 敏感：只要子查询结果集中有一个 NULL，`x NOT IN (...)` 对所有 x 都返回 NULL（即不匹配），
导致结果集错误地为空。这是 NOT IN 最危险的隐患。

::: warning NOT IN 两大问题
1. **性能差**：子查询物化 + 逐行匹配，无法利用索引反连接
2. **NULL 陷阱**：子查询结果含 NULL 时，整个 NOT IN 语义错误，结果集为空
:::
