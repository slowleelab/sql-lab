# NOT IN vs LEFT JOIN IS NULL

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['NOT IN', 'LEFT JOIN', '反连接', '子查询改写']" />

## 查询"没有下过订单的用户"
查询"没有下过订单的用户"，开发者最直觉的写法是 `NOT IN` 子查询。但这个写法有两个致命问题：性能差（子查询物化 + 逐行匹配），还有 NULL 陷阱（子查询结果含 NULL 时整个查询返回空）。

```sql
-- NOT IN 子查询查无订单用户
SELECT id, username
FROM t_user_check
WHERE id NOT IN (SELECT user_id FROM t_order_check);
```

10 万用户 + 20 万订单的数据下，EXPLAIN 显示子查询未被优化为半连接，`SELECT user_id FROM t_order_check` 物化为 20 万行的临时结构，再对用户表逐行检查 id 是否在其中。耗时约 350ms，且如果 `t_order_check.user_id` 有 NULL 值，结果集直接为空--语义错误。

改写为 `LEFT JOIN ... IS NULL`（反连接）后，优化器可用索引高效完成，且不受 NULL 干扰，耗时降至约 40ms。

::: warning 真实场景
"找出没有 XXX 的 YYY"是极其常见的业务查询--没有下过单的用户、没有评论过的文章、没有绑定手机的用户。NOT IN 是最直觉但也最危险的写法，NULL 陷阱可能在数据变化后突然触发，导致线上故障。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: NOT IN 子查询查无订单用户
-- 子查询 SELECT user_id FROM t_order_check 物化为临时表，逐行匹配，性能差
SELECT id, username
FROM t_user_check
WHERE id NOT IN (SELECT user_id FROM t_order_check);
```

### EXPLAIN 结果

```
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
| id | select_type | table         | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
|  1 | PRIMARY     | t_user_check  | ALL   | NULL          | NULL       | NULL    | NULL |  99812 |   100.00 | Using where |
|  2 | SUBQUERY    | t_order_check | index | NULL          | idx_user_id| 8       | NULL | 198624 |   100.00 | Using index |
+----+-------------+---------------+-------+---------------+------------+---------+------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | PRIMARY + SUBQUERY | **子查询未被优化为半连接** |
| table 1 type | `ALL` | 用户表全表扫描 |
| table 2 type | `index` | 子查询扫描整个 idx_user_id 索引 |
| rows (subquery) | ~198,624 | 子查询物化 20 万行 user_id |

### 为什么慢

`NOT IN` 子查询的执行逻辑：

1. **子查询物化**：先执行 `SELECT user_id FROM t_order_check`，把 20 万个 user_id 收集到临时结构
2. **逐行匹配**：对 t_user_check 的每一行（10 万行），检查其 id 是否在子查询结果集中
3. **无法用索引短路**：NOT IN 是"否定"语义，优化器难以转化为高效的索引反连接

更危险的是 NOT IN 的 NULL 陷阱：

```sql
-- 若 t_order_check.user_id 含 NULL，NOT IN 永远返回空！
SELECT 1 WHERE 1 NOT IN (2, 3, NULL);  -- 结果: 空（NULL 导致整个表达式为 NULL）
```

NOT IN 对 NULL 敏感：只要子查询结果集中有一个 NULL，`x NOT IN (...)` 对所有 x 都返回 NULL（即不匹配），导致结果集错误地为空。

::: warning NOT IN 两大问题
1. **性能差**：子查询物化 + 逐行匹配，无法利用索引反连接
2. **NULL 陷阱**：子查询结果含 NULL 时，整个 NOT IN 语义错误，结果集为空
:::

::: tip 核心认知
NOT IN 子查询无法被优化为高效的索引反连接，且对 NULL 敏感。改写为 LEFT JOIN ... IS NULL 后，优化器识别为反连接，用索引 + Not exists 短路高效完成。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 改写为 LEFT JOIN ... IS NULL（反连接 Anti Join）
-- 优化器可用索引高效完成，且不受 NULL 值干扰
SELECT u.id, u.username
FROM t_user_check u
LEFT JOIN t_order_check o ON o.user_id = u.id
WHERE o.id IS NULL;
```

### 原理

`LEFT JOIN ... IS NULL` 被优化器识别为**反连接（Anti Join）**：

1. **无子查询物化**：改写为 JOIN，不再需要收集子查询结果集
2. **索引驱动**：对每个用户，用 idx_user_id 索引快速查找是否有订单
3. **Not exists 短路**：`Not exists` 表示找到第一条匹配即知道该用户"有订单"，立即跳过（无需继续扫描）
4. **无 NULL 陷阱**：LEFT JOIN 的 `o.id IS NULL` 判断不受 user_id 列 NULL 值影响

执行流程（优化后）：

```
1. 遍历 t_user_check 每个用户 u（10 万行）
2. 对每个 u，用 idx_user_id 索引查找 o.user_id = u.id
3. 若索引未命中（无订单）-> o.id IS NULL 成立 -> 输出该用户
4. 若索引命中（有订单）-> 跳过（Not exists 短路）
```

三种反连接写法对比：

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

### 对比

| | bad.sql (NOT IN) | good.sql (LEFT JOIN) |
|---|---|---|
| 子查询物化 | 是（20 万行临时结构） | 否 |
| 索引使用 | 子查询全索引扫描 | 索引 ref 查找 |
| Extra | Using where | Not exists |
| NULL 安全 | 不安全（陷阱） | 安全 |
| 耗时 | ~350 ms | ~40 ms |

<ExplainCompare
  :bad="{ type: 'ALL + SUBQUERY', key: 'NULL + idx_user_id', rows: '99,812 + 198,624', Extra: 'Using where（子查询物化）' }"
  :good="{ type: 'ALL + ref', key: 'NULL + idx_user_id', rows: '99,812 + 2', Extra: 'Using where; Not exists（反连接短路）' }"
  improvement="消除子查询物化，Not exists 短路 + 索引查找，耗时下降约 8 倍"
/>

## 避坑指南

::: warning 注意事项

1. **NOT IN 的 NULL 陷阱是最危险的隐患**。子查询结果集只要有一个 NULL，`NOT IN` 对所有值都返回 NULL（不匹配），结果集错误地为空。这个 bug 可能在数据变化后突然出现，难以排查。改用 LEFT JOIN IS NULL 或 NOT EXISTS 可彻底避免。

2. **关联列必须有索引**。LEFT JOIN 方案的效率依赖被关联表（t_order_check）的关联列（user_id）上有索引。如果没有索引，LEFT JOIN 退化为嵌套循环全表扫描，比 NOT IN 更慢。

3. **NOT EXISTS 也是好选择**。`NOT EXISTS` 同样 NULL 安全，性能接近 LEFT JOIN IS NULL。可读性上 NOT EXISTS 更直观（"不存在"语义清晰），LEFT JOIN IS NULL 稍隐晦但对优化器更友好。

4. **8.0 优化器对 NOT IN 有改进**。8.0 的优化器在某些场景下能将 NOT IN 转化为反连接，但并非所有场景都生效。为了可预测的性能和 NULL 安全，仍建议主动改写。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| NOT IN 子查询优化 | 部分场景可转化为半连接 | 更多场景可转化，但仍不稳定 |
| LEFT JOIN IS NULL 反连接 | ✅ Not exists 优化 | ✅ Not exists 优化 |
| NOT EXISTS 优化 | ✅ 支持 | ✅ 支持 |
| NULL 陷阱 | ✅ 存在 | ✅ 存在 |

::: tip 选择建议
- **LEFT JOIN ... IS NULL**：性能最佳，推荐（本案例）
- **NOT EXISTS**：NULL 安全，性能接近 LEFT JOIN，可读性好
- **NOT IN**：避免使用，性能差且有 NULL 陷阱
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 25-not-in-vs-left-join

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 25-not-in-vs-left-join --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 25-not-in-vs-left-join --no-seed
```
