# 隐式类型转换致索引失效

<CaseMeta difficulty="⭐⭐" category="索引" versions="5.7 & 8.0" :tags="['类型转换', '索引失效', 'VARCHAR', '手机号查询']" />

## 隐式转换：手机号是数字类型却走不上索引
用户登录时，前端传来的手机号是数字类型（`13800138000`），后端没有转换为字符串就直接拼进了 SQL：

```sql
-- 后端代码: "SELECT * FROM t_user WHERE phone = " + phone
-- phone 变量是数字类型，拼接后没有引号
SELECT * FROM t_user WHERE phone = 13800138000;
```

用户表 50 万行，手机号字段明明建了唯一索引，但查询却要 **90ms**，慢查询告警频发。

::: warning 真实场景
这是生产环境最高频的索引失效原因之一。特别是 Java/Go 后端，如果用 MyBatis 的 `#{phone}` 传参时类型不对，或者直接字符串拼接数字，就会踩坑。
:::

## 问题分析

### bad.sql

```sql
SELECT id, username, phone, email, status
FROM t_user
WHERE phone = 13800138000;   -- ← 没加引号，传了数字
```

### EXPLAIN 结果

```
+----+--------+--------+------+---------------+------+---------+------+--------+-------------+
| id | table  | type   | key  | possible_keys | ref  | rows    | Extra                |
+----+--------+--------+------+---------------+------+---------+----------------------+
|  1 | t_user | ALL    | NULL | uk_phone      | NULL | 495,079 | Using where          |
+----+--------+--------+------+---------------+------+---------+----------------------+
```

`possible_keys` 显示有 `uk_phone` 索引可用，但 `key = NULL` 表示**实际没用上**，`type = ALL` 全表扫描。

### 为什么索引失效

MySQL 的隐式类型转换规则：**当字符串列与数字比较时，把字符串转为数字**。

MySQL 实际执行的是：
```sql
WHERE CAST(phone AS SIGNED) = 13800138000
```

对 `phone` 列套了 `CAST()` 函数，而**函数操作会破坏索引查找**（索引存的是原始字符串值，不是 CAST 后的值）。优化器只能放弃索引，全表扫描逐行 CAST 后比较。

::: tip 核心认知
不是"传错了类型 MySQL 会自动修正"，而是"类型不匹配时 MySQL 会在列上加函数转换，导致索引失效"。
:::

## 优化方案

### 方案：传入正确类型的字符串

```sql
-- good.sql
SELECT id, username, phone, email, status
FROM t_user
WHERE phone = '13800138000';  -- ← 加引号，传字符串
```

### 原理

`phone` 列是 `VARCHAR(11)`，传入字符串 `'13800138000'` 后类型完全匹配，无需转换。

- 直接走 `uk_phone` 唯一索引
- `type = const`（最优访问类型），O(1) 查找

### 对比

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL (索引失效)', rows: '495,079', Extra: 'Using where' }"
  :good="{ type: 'const', key: 'uk_phone', rows: '1', Extra: 'NULL (无额外操作)' }"
  improvement="扫描行数下降 495,079 倍，耗时 90ms → 1ms"
/>

## 避坑指南

::: warning 常见类型转换陷阱

1. **VARCHAR 列传数字**（本案例）-- 最常见
   ```sql
   WHERE phone = 13800138000     -- ❌ 索引失效
   WHERE phone = '13800138000'   -- ✅ 走索引
   ```

2. **INT 列传字符串** -- MySQL 会把字符串转数字，**索引不失效**
   ```sql
   WHERE id = '123'    -- ✅ MySQL 转为数字比较，索引仍有效
   ```
   这是不对称的！VARCHAR 传数字会失效，INT 传字符串不会。

3. **DECIMAL 列传字符串** -- 类似 INT，不会失效

4. **ORM 框架注意**：
   - MyBatis：`#{phone}` 会自动加引号，但如果 Java 类型是 `Long`，可能传数字
   - JPA/Hibernate：确保实体类字段类型与数据库列类型一致
   - Go database/sql：`interface{}` 传 `int64` 会导致类型不匹配

5. **排查方法**：如果 EXPLAIN 的 `possible_keys` 有值但 `key = NULL`，首先怀疑类型不匹配。
:::

## 5.7 vs 8.0 差异

两个版本行为完全一致，隐式类型转换规则没有变化。这也是为什么这个坑如此常见--从 5.7 到 8.0 都存在。

## 本地复现

```bash
./scripts/run-case.sh 03-implicit-type-conversion
./scripts/run-case.sh 03-implicit-type-conversion --ver 5.7
```
