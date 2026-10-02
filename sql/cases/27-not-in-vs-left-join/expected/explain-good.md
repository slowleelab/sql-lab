# EXPLAIN 参考结果 - good.sql (LEFT JOIN IS NULL 反连接)

## MySQL 8.0（实测 8.0.46，10 万用户 + 20 万订单）

```
+----+-------------+---------------+------+---------------+------------+---------+------------------+--------+----------+-------------------------+
| id | select_type | table         | type | possible_keys | key        | key_len | ref               | rows   | filtered | Extra                   |
+----+-------------+---------------+------+---------------+------------+---------+------------------+--------+----------+-------------------------+
|  1 | SIMPLE      | u             | ALL  | NULL          | NULL       | NULL    | NULL             |  99812 |   100.00 | NULL                    |
|  1 | SIMPLE      | o             | ref  | idx_user_id   | idx_user_id| 8       | sql_treasure.u.id |      2 |   100.00 | Using where; Not exists |
+----+-------------+---------------+------+---------------+------------+---------+------------------+--------+----------+-------------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | **全是 SIMPLE** | **无子查询，已被改写为 JOIN** |
| table o type | `ref` | 用 idx_user_id 索引查找 |
| table o ref | `sql_treasure.u.id` | 关联条件用上了用户 id |
| table o Extra | **`Not exists`** | **反连接优化！**检测到无匹配行即跳过 |

## 为什么更好

`LEFT JOIN ... IS NULL` 被优化器识别为**反连接（Anti Join）**：

1. **无子查询物化**：改写为 JOIN，不再需要收集子查询结果集
2. **索引驱动**：对每个用户，用 idx_user_id 索引快速查找是否有订单
3. **Not exists 短路**：`Not exists` 表示找到第一条匹配即知道该用户"有订单"，立即跳过（无需继续扫描）
4. **无 NULL 陷阱**：LEFT JOIN 的 `o.id IS NULL` 判断不受 user_id 列 NULL 值影响

### 执行流程（优化后）

```
1. 遍历 t_user_check 每个用户 u（10 万行）
2. 对每个 u，用 idx_user_id 索引查找 o.user_id = u.id
3. 若索引未命中（无订单）-> o.id IS NULL 成立 -> 输出该用户
4. 若索引命中（有订单）-> 跳过（Not exists 短路）
```

## 量化对比

| 指标 | bad.sql (NOT IN) | good.sql (LEFT JOIN) | 提升 |
|------|------------------|----------------------|------|
| 子查询物化 | 是（20 万行临时结构） | 否 | **消除物化** |
| 索引使用 | 子查询全索引扫描 | 索引 ref 查找 | 精准定位 |
| Extra | Using where | **Not exists** | 反连接短路 |
| NULL 安全 | 不安全（陷阱） | 安全 | 语义正确 |
| 耗时 | ~350 ms | ~40 ms | **约 8 倍** |

## 三种反连接写法对比

```sql
-- 写法 1: NOT IN（差，NULL 不安全）
SELECT * FROM t_user_check
WHERE id NOT IN (SELECT user_id FROM t_order_check);

-- 写法 2: LEFT JOIN IS NULL（推荐，索引友好）
SELECT u.* FROM t_user_check u
LEFT JOIN t_order_check o ON o.user_id = u.id
WHERE o.id IS NULL;

-- 写法 3: NOT EXISTS（良好，NULL 安全，但比 LEFT JOIN 稍慢）
SELECT * FROM t_user_check u
WHERE NOT EXISTS (SELECT 1 FROM t_order_check o WHERE o.user_id = u.id);
```

::: tip 选择建议
- **LEFT JOIN ... IS NULL**：性能最佳，推荐（本案例）
- **NOT EXISTS**：NULL 安全，性能接近 LEFT JOIN，可读性好
- **NOT IN**：避免使用，性能差且有 NULL 陷阱
:::
