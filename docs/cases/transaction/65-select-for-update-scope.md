# SELECT FOR UPDATE 锁范围

<CaseMeta difficulty="⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['FOR UPDATE', '锁升级', '行锁', '表锁']" />

## 1205 阻塞：FOR UPDATE 锁全表
商品库存管理系统中，后台对账脚本执行 `SELECT * FROM t_product WHERE category = '电子' FOR UPDATE` 锁定电子产品做盘点。此时整个商品表的更新全部卡住--连非电子产品（如食品类 id=1）的库存扣减也被阻塞，最终报 `ERROR 1205 Lock wait timeout exceeded`。

```sql
-- 会话A：category 字段无索引，FOR UPDATE 锁全表
BEGIN;
SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
-- category 无索引 -> 全表扫描 -> 锁定所有行（表锁效果）

-- 会话B：更新非电子行也被阻塞
BEGIN;
UPDATE t_product SET stock = stock - 1 WHERE id = 1;
-- ❌ 被阻塞！虽然 id=1 可能不是电子产品，但整表已被锁
```

问题根因：`category` 字段**没有索引**，`FOR UPDATE` 无法通过索引定位行，退化为全表扫描并对**所有扫描到的行加 X 锁**，效果等同于表锁。

::: warning 真实场景
这是 FOR UPDATE 最常见的性能陷阱。很多开发者以为 `FOR UPDATE` 只锁匹配行，却忽略了 WHERE 条件必须走索引这一前提。一旦过滤字段无索引，整张表被锁，所有并发更新全部排队，线上表现为"某个对账任务一跑，整张表就卡死"。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: WHERE 条件无索引，FOR UPDATE 锁升级为表锁
-- category 字段无索引，SELECT FOR UPDATE 无法走索引定位，退化为全表扫描加锁
-- 导致整张表所有行被锁，其他事务对该表任意行的更新/插入均被阻塞
--
-- 复现步骤（需两个会话）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
--     -- category 无索引 -> 全表扫描 -> 锁定所有行（表锁效果）
--
--   会话B（被阻塞）:
--     BEGIN;
--     UPDATE t_product SET stock = stock - 1 WHERE id = 1;
--     -- ❌ 被阻塞！虽然 id=1 可能不是电子产品，但整表已被锁

BEGIN;

-- category 无索引，FOR UPDATE 锁全表（所有行加锁）
SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;

-- 此时整表被锁，不 COMMIT，切换到会话B验证任意行更新被阻塞
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
| id | select_type | table      | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra |
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
|  1 | SIMPLE      | t_product  | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 100155 |    20.00 | NULL  |
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | **全表扫描**，无索引可用 |
| possible_keys | `NULL` | 没有任何候选索引 |
| key | `NULL` | 未使用索引 |
| rows | ~100,155 | 扫描全部 10 万行 |
| filtered | 20.00 | 约 20% 行匹配（5 个分类各约 2 万） |

### 为什么慢

FOR UPDATE 需要**对所有扫描到的行加排他锁（X 锁）**。category 无索引导致全表扫描，每行都被加 X 锁，虽然只有 `category='电子'` 的行匹配，但扫描过程中**所有行都被锁**。

```
无索引时的加锁行为：
时间线   会话A（无索引 FOR UPDATE）          会话B（任意行更新被阻塞）
  T1     BEGIN;
  T2     SELECT ... WHERE category='电子'
            FOR UPDATE;   -- 全表扫描，锁所有行
  T3                                        BEGIN;
  T4                                        UPDATE t_product SET stock=stock-1 WHERE id=1;
                                            -- ❌ 被阻塞！id=1 即使不是电子产品也被锁
  T5     （未提交）
  T6                                        超时：ERROR 1205 Lock wait timeout exceeded
```

锁范围的影响：

| 操作 | 是否被阻塞 | 原因 |
|------|-----------|------|
| UPDATE 任意行 | **是** | 全表行锁 |
| DELETE 任意行 | **是** | 全表行锁 |
| INSERT 新行 | **是** | 插入意向锁与行锁冲突 |
| 其他事务 SELECT（无锁） | 否 | 普通读不加锁 |

::: tip 核心认知
`FOR UPDATE` 的锁范围 = 扫描范围。WHERE 不走索引时扫描全表，锁也锁全表。**FOR UPDATE 的 WHERE 必须走索引**，这是锁性能的第一原则。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 给 category 加索引后，FOR UPDATE 只锁匹配行（行锁）
-- 配合 setup-good.sql 执行 ALTER TABLE 添加 idx_category 索引
-- 索引定位后只对 category='电子' 的行加锁，其他分类的行不受影响
--
-- 复现步骤（先执行 setup-good.sql 加索引）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
--     -- 走 idx_category 索引 -> 只锁 category='电子' 的行
--
--   会话B（不被阻塞）:
--     BEGIN;
--     UPDATE t_product SET stock = stock - 1 WHERE id = 1;
--     -- ✅ 若 id=1 不是电子产品则不被阻塞（即使 update 电子行也仅等对应行锁）

BEGIN;

-- category 有索引，FOR UPDATE 只锁匹配的行
SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;

COMMIT;
```

配合 `setup-good.sql` 添加索引：

```sql
-- setup-good.sql: 给 category 字段加索引，使 FOR UPDATE 走索引定位行锁
ALTER TABLE t_product ADD KEY idx_category (category);
```

### 原理

有索引后，FOR UPDATE 通过 `idx_category` 索引定位到 `category='电子'` 的行，只对**实际匹配的行加 X 锁**。其他分类的行不被扫描、不加锁，可正常更新。

```
有索引时的加锁行为：
时间线   会话A（有索引 FOR UPDATE）          会话B（非电子行更新成功）
  T1     BEGIN;
  T2     SELECT ... WHERE category='电子'
            FOR UPDATE;   -- 走索引，只锁电子产品
  T3                                        BEGIN;
  T4                                        UPDATE t_product SET stock=stock-1
                                            WHERE id = 1 AND category <> '电子';
                                            -- ✅ 不被阻塞（非电子行未加锁）
```

进一步优化：用主键精确加锁只锁单行，锁范围最小：

```sql
-- 只锁 id=100 这一行（记录锁，影响最小）
SELECT * FROM t_product WHERE id = 100 FOR UPDATE;
-- rows=1，只锁 1 行，并发性能最佳
```

### 对比

| | bad.sql（无索引） | good.sql（有索引） | 主键精确 |
|---|---|---|---|
| type | ALL | ref | const |
| 扫描行数 | ~100,155 | ~20,031 | 1 |
| 锁定行数 | 全表（10 万行） | ~20,031（实际含间隙锁，锁范围更大） | 1（next-key lock 仅锁单行+前后间隙） |
| 并发更新 | 全部阻塞 | 仅电子行阻塞 | 仅 1 行阻塞 |
| 锁等待概率 | 极高 | 中 | 极低 |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '100,155', Extra: '全表扫描+锁全表（表锁效果）' }"
  :good="{ type: 'ref', key: 'idx_category', rows: '20,031', Extra: '索引定位，仅锁匹配行' }"
  improvement="锁范围从 10 万行缩小到 2 万行，非电子行更新不再阻塞"
/>

## 避坑指南

::: warning 注意事项

1. **FOR UPDATE 的 WHERE 必须走索引**：无索引 = 表锁，这是最常见的锁性能陷阱。

2. **优先主键加锁**：业务允许时用 `WHERE id=N FOR UPDATE`，只锁单行。

3. **区分度高才加索引**：category 只有 5 个值（区分度低），索引效果有限；高区分度字段加索引收益更大。

4. **RR 下普通索引还会加间隙锁**：即使有索引，RR 下普通索引等值/范围仍可能加 next-key lock，考虑 RC。

5. **缩短持锁时间**：FOR UPDATE 后立即做业务操作并 COMMIT，不要在锁内做耗时操作。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 无索引锁全表 | ✅ 一致（表锁效果） | ✅ 一致（表锁效果） |
| 有索引只锁匹配行 | ✅ 有效 | ✅ 有效 |
| 锁行数验证 | `SHOW ENGINE INNODB STATUS` 间接分析 | `performance_schema.data_locks` 精确统计 |
| RR 下普通索引间隙锁 | 会加 next-key lock | 会加 next-key lock |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 65-select-for-update-scope

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 65-select-for-update-scope --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 65-select-for-update-scope --no-seed
```
