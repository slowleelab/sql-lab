# 死锁排查与分析

<CaseMeta difficulty="⭐⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['死锁', 'gap lock', 'next-key lock', '事务顺序']" />

## 场景痛点

电商系统的订单处理模块，两个定时任务并行处理同一批订单：任务A先更新订单1再更新订单2，任务B先更新订单2再更新订单1。在线上高峰期频繁出现 `ERROR 1213 (40001): Deadlock found when trying to get lock`，导致部分订单处理失败、需要人工重试。

```sql
-- 事务A的更新顺序：先 id=1 再 id=2
BEGIN;
UPDATE t_order_deadlock SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW() WHERE id = 1;
UPDATE t_order_deadlock SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW() WHERE id = 2;
COMMIT;

-- 事务B的更新顺序相反：先 id=2 再 id=1
BEGIN;
UPDATE t_order_deadlock SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW() WHERE id = 2;
UPDATE t_order_deadlock SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW() WHERE id = 1;
COMMIT;
```

两条 UPDATE 单独执行都是主键等值定位，毫秒级完成。但当它们以**相反的加锁顺序**并发执行时，就形成了循环等待，触发 InnoDB 死锁检测。

::: warning 真实场景
这是高并发事务系统中最典型的死锁形态。任何"多行更新"的操作——批量状态流转、跨账户转账、订单履约链路——只要不同事务的加锁顺序不一致，就会在并发下踩到死锁。线上偶发的 1213 错误，大概率根因就在这里。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 事务A的更新顺序（先更新订单1，再更新订单2）
-- 事务B的更新顺序相反（先更新订单2，再更新订单1），两者交叉加锁导致死锁
--
-- 时间线：
--   T1  事务A: BEGIN; UPDATE ... WHERE id=1;   -- 持有 id=1 行锁
--   T2  事务B: BEGIN; UPDATE ... WHERE id=2;   -- 持有 id=2 行锁
--   T3  事务A: UPDATE ... WHERE id=2;          -- 等待 id=2 行锁（被B持有）
--   T4  事务B: UPDATE ... WHERE id=1;          -- 等待 id=1 行锁（被A持有）=> 死锁！
--
-- 注意：本脚本仅展示事务A的语句。需在两个会话中分别按相反顺序执行才能复现死锁。
-- InnoDB 检测到死锁后会自动回滚其中一个事务（victim），报错 ERROR 1213 (40001)

BEGIN;

-- 事务A：先更新 id=1（顺序为 1 -> 2）
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 1;

-- 事务A：再更新 id=2
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 2;

COMMIT;
```

### EXPLAIN 结果

死锁场景无法用单条 EXPLAIN 完整展示，需结合两条 UPDATE 的执行计划与锁等待分析。

```
-- EXPLAIN UPDATE t_order_deadlock SET ... WHERE id = 1;
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_order_deadlock  | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

单条 UPDATE 走主键等值定位（`type=const`，`rows=1`），性能没有问题。**问题出在两个事务的加锁顺序不一致**。

### 为什么慢

```
死锁复现步骤（需两个会话）：

时间线   会话A（事务A，顺序 1->2）        会话B（事务B，顺序 2->1）
  T1     BEGIN;
  T2                                      BEGIN;
  T3     UPDATE ... WHERE id=1;  -- 锁定 id=1
  T4                                      UPDATE ... WHERE id=2;  -- 锁定 id=2
  T5     UPDATE ... WHERE id=2;  -- 等待 id=2 锁（B 持有）
  T6                                      UPDATE ... WHERE id=1;  -- 等待 id=1 锁（A 持有）
                  => 循环等待，InnoDB 死锁检测器介入
                  => 回滚 victim 事务，报错：
                     ERROR 1213 (40001): Deadlock found when trying to get lock;
                     try restarting transaction
```

锁等待图：

```
  事务A ──持有──> 锁 id=1 ──等待──> 锁 id=2 <──持有── 事务B
     ^                                                 |
     └──────────────── 循环等待 ────────────────────────┘
```

- 事务A 持有 id=1 行锁，等待 id=2 行锁
- 事务B 持有 id=2 行锁，等待 id=1 行锁
- 两个事务互相持有对方需要的锁，形成**循环等待环**，InnoDB 死锁检测器介入，主动回滚代价较小的事务（victim）

::: tip 核心认知
死锁的根因不是单条 SQL 慢，而是**多行更新的加锁顺序不一致**。只要保证所有事务按相同顺序加锁，循环等待就不会形成。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 按一致的加锁顺序更新（总是先更新 id 小的，再更新 id 大的）
-- 事务A和事务B都遵循 1 -> 2 的顺序，不会形成循环等待，避免死锁
--
-- 时间线：
--   T1  事务A: BEGIN; UPDATE ... WHERE id=1;   -- 持有 id=1 行锁
--   T2  事务B: BEGIN; UPDATE ... WHERE id=1;   -- 等待 id=1 行锁
--   T3  事务A: UPDATE ... WHERE id=2;          -- 持有 id=2 行锁
--   T4  事务A: COMMIT;                         -- 释放 id=1、id=2 行锁
--   T5  事务B: 获取 id=1 行锁，UPDATE id=1 完成
--   T6  事务B: UPDATE ... WHERE id=2;
--   T7  事务B: COMMIT;
--   => 事务A先执行完，事务B串行等待，无死锁
--
-- 复现说明：在两个会话中分别执行下面的语句（按相同顺序），不会死锁，只会等待

BEGIN;

-- 总是先更新 id 小的行
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 1;

-- 再更新 id 大的行
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id = 2;

COMMIT;
```

### 原理

把两个事务的加锁顺序统一为 **id 升序（1 -> 2）**，形成的是单向等待链而非循环等待：

```
一致加锁顺序的执行时间线：

时间线   会话A（顺序 1->2）               会话B（顺序 1->2）
  T1     BEGIN;
  T2                                      BEGIN;
  T3     UPDATE ... WHERE id=1;  -- 锁定 id=1
  T4                                      UPDATE ... WHERE id=1;  -- 等待 id=1 锁
  T5     UPDATE ... WHERE id=2;  -- 锁定 id=2
  T6     COMMIT;                  -- 释放 id=1、id=2
  T7                                      获取 id=1 锁，UPDATE id=1 完成
  T8                                      UPDATE ... WHERE id=2;
  T9                                      COMMIT;
         => 事务B 等待事务A 完成，串行执行，无死锁
```

锁等待图（无环）：

```
  事务A ──持有──> 锁 id=1, id=2
  事务B ──等待──> 锁 id=1（仅单向等待，无循环）
```

事务B 只是等待事务A 释放锁，不会出现互相等待，因此永远不会死锁。

更优方案是将多条 UPDATE 合并为单条 `WHERE id IN (...)`，InnoDB 单语句内部保证加锁顺序：

```sql
-- 更优：合并为单条语句（InnoDB 单语句内部保证加锁顺序）
BEGIN;
UPDATE t_order_deadlock
SET status = 'PROCESSING', amount = amount + 1.00, updated_at = NOW()
WHERE id IN (1, 2);
COMMIT;
```

### 对比

| | bad.sql（反向加锁） | good.sql（一致顺序） |
|---|---|---|
| 事务A加锁顺序 | id=1 -> id=2 | id=1 -> id=2 |
| 事务B加锁顺序 | id=2 -> id=1（反向） | id=1 -> id=2（一致） |
| 循环等待 | 存在（死锁） | 不存在（串行等待） |
| 死锁概率 | 高（并发下高概率） | **0** |
| 事务回滚 | victim 被回滚需重试 | 无需重试 |
| 吞吐量 | 重试浪费 CPU | 稳定 |

<ExplainCompare
  :bad="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: 'Using where（反向加锁→死锁）' }"
  :good="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: 'Using where（一致顺序→无死锁）' }"
  improvement="执行计划不变，统一加锁顺序消除循环等待，死锁概率降为 0"
/>

## 避坑指南

::: warning 注意事项

1. **固定加锁顺序**：对多行更新，始终按主键（或唯一键）升序加锁，这是最根本的防死锁手段。

2. **按索引访问**：UPDATE/DELETE 的 WHERE 条件必须走索引，无索引会退化为表级锁（RR 下更严重，会加大量间隙锁）。

3. **缩短事务**：事务越小，持锁时间越短，死锁窗口越窄；避免在事务中穿插慢操作（远程调用、文件 IO）。

4. **批量更新用 IN**：将多条 UPDATE 合并为 `WHERE id IN (1,2)` 一条语句，InnoDB 内部按顺序加锁且不会跨语句死锁。

5. **降低隔离级别**：在业务允许时使用 RC，避免 RR 下的大量 next-key lock。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 死锁检测机制 | 自动检测并回滚 victim | 一致，自动检测并回滚 victim |
| 锁信息查看 | `SHOW ENGINE INNODB STATUS` 间接分析 | `performance_schema.data_locks` 直接查看锁 |
| 死锁检测开关 | 固定开启 | `innodb_deadlock_detect` 可关闭（高并发降开销） |
| 一致加锁顺序方案 | ✅ 有效 | ✅ 有效 |

::: tip 8.0 死锁排查
8.0 中开启死锁全量记录后，可直接查看锁详情：

```sql
SET GLOBAL innodb_print_all_deadlocks = ON;
SHOW ENGINE INNODB STATUS\G   -- LATEST DETECTED DEADLOCK 段
SELECT * FROM performance_schema.data_locks;
SELECT * FROM performance_schema.data_lock_waits;
```
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 63-deadlock-analysis

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 63-deadlock-analysis --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 63-deadlock-analysis --no-seed
```
