# 索引下推 ICP（Index Condition Pushdown）

<CaseMeta difficulty="⭐⭐⭐" category="索引" versions="5.6 & 5.7 & 8.0" :tags="['ICP', '索引下推', 'Using index condition', '回表']" />

## 手机号前缀 + 姓名模糊：索引下推 ICP 提速
用户搜索功能，按手机号前缀 + 姓名模糊查询：

```sql
SELECT * FROM t_user_icp
WHERE phone_prefix = '1380' AND name LIKE '张%';
```

联合索引 `(phone_prefix, name)` 上明明有索引，`name LIKE '张%'` 也能用索引范围扫描，但查询还是不快。EXPLAIN 显示 `Using where` 而不是 `Using index condition`，大量无效回表。

::: warning 真实场景
ICP 是 MySQL 5.6 引入的优化。如果你的查询涉及联合索引 + LIKE/范围条件，ICP 能大幅减少回表次数。但很多人不知道如何确认 ICP 是否生效。
:::

## 问题分析

### bad.sql（关闭 ICP）

```sql
-- 关闭 ICP: SET SESSION optimizer_switch='index_condition_pushdown=off';
SELECT id, phone_prefix, name, phone, city
FROM t_user_icp
WHERE phone_prefix = '1380' AND name LIKE '张%';
```

### EXPLAIN 结果

```
+----+------------+-------+----------------+---------+-------+----------+-------------+
| id | table      | type  | key            | rows    | filtered| Extra                  |
+----+------------+-------+----------------+---------+--------+------------------------+
|  1 | t_user_icp | range | idx_prefix_name| 17,682  | 100.00 | Using where            |
+----+------------+-------+----------------+---------+--------+------------------------+
```

`Extra = Using where` 表示 `name LIKE '张%'` 条件在 **server 层**（回表后）才判断。

### 为什么慢

关闭 ICP 时的执行流程：

```
1. 存储引擎: 从 idx_prefix_name 索引找到 phone_prefix='1380' 的行 → 4万行
2. 存储引擎: 逐行回表读取完整行数据 → 4万次回表
3. server层: 用 name LIKE '张%' 过滤 → 只剩 2000 行
4. 返回 2000 行
```

**3.8 万次回表是无效的**--这些行的 name 不匹配 `张%`，回表读取的数据被丢弃。

## 优化方案

### 方案：确保 ICP 开启（5.6+ 默认开启）

```sql
-- 开启 ICP: SET SESSION optimizer_switch='index_condition_pushdown=on';
SELECT id, phone_prefix, name, phone, city
FROM t_user_icp
WHERE phone_prefix = '1380' AND name LIKE '张%';
```

### 原理

ICP（Index Condition Pushdown）将 WHERE 条件**下推到存储引擎层**，在索引上直接判断，避免无效回表。

开启 ICP 时的执行流程：

```
1. 存储引擎: 从 idx_prefix_name 索引找到 phone_prefix='1380' 的行 → 4万行
2. 存储引擎: 在索引上用 name LIKE '张%' 过滤 → 只剩 2000 行（不回表！）
3. 存储引擎: 只对 2000 行回表读取完整数据
4. server层: 返回 2000 行
```

回表次数从 **4 万次降到 2000 次**。

### 对比

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_prefix_name', rows: '17,682', Extra: 'Using where (回表后过滤)' }"
  :good="{ type: 'range', key: 'idx_prefix_name', rows: '17,682', Extra: 'Using index condition (索引层过滤)' }"
  improvement="回表次数减少 ~88%，耗时 120ms -> 45ms"
/>

## 避坑指南

::: warning 注意事项

1. **ICP 只对联合索引有效**。单列索引没有"下推"的意义，因为条件只能用索引列或非索引列过滤。

2. **ICP 只对二级索引有效**，聚簇索引（主键）不需要 ICP（本身就是完整行）。

3. **LIKE 的前导通配符会阻止 ICP**。`LIKE '%张'` 的条件无法下推（无法在索引上判断），只有 `LIKE '张%'` 可以。

4. **如何确认 ICP 生效**：看 EXPLAIN 的 Extra：
   - `Using index condition` → ICP 生效 ✅
   - `Using where` → ICP 未生效或条件无法下推 ❌

5. **5.6 之前没有 ICP**。5.5 及更早版本所有条件都在 server 层判断，回表代价极高。
:::

## 5.7 vs 8.0 差异

ICP 在 5.6 引入，5.7 和 8.0 默认开启，行为一致。两个版本的 EXPLAIN 输出格式相同。

## 本地复现

```bash
./scripts/run-case.sh 09-index-condition-pushdown
```
