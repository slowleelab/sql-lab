# RC vs RR 隔离级别锁行为差异

<CaseMeta difficulty="⭐⭐⭐" category="事务" versions="5.7 & 8.0" :tags="['隔离级别', 'next-key lock', 'gap lock', '并发插入']" />

## 1205 阻塞：同一用户下单被卡住
订单系统中，客服需要锁定某个用户的已支付订单进行对账。事务A执行 `SELECT ... WHERE user_id = 100 AND status = 1 FOR UPDATE` 锁定该用户的已支付订单。与此同时，事务B尝试为同一用户创建一笔新订单（`INSERT INTO t_order ... user_id = 100, status = 0`），结果被长时间阻塞，最终报 `ERROR 1205 (HY000): Lock wait timeout exceeded`。

```sql
-- 会话A（RR 隔离级别，MySQL 默认）：
BEGIN;
SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;
-- 不提交，保持锁

-- 会话B：
BEGIN;
INSERT INTO t_order (order_no, user_id, amount, status)
VALUES ('NO999999', 100, 99.00, 0);
-- 被阻塞！等待会话A释放锁
-- 超时后报错：ERROR 1205 (HY000): Lock wait timeout exceeded
```

明明插入的是 `status = 0`（待支付），查询条件是 `status = 1`（已支付），**完全不同的行**，为什么插入会被阻塞？因为 RR 隔离级别下，`FOR UPDATE` 不只锁命中的行，还会锁住索引区间内的**间隙**，防止幻读。新插入的 `(100, 0)` 落在被锁定的间隙内，被间隙锁挡住。

::: warning 真实场景
这是 RR 隔离级别（MySQL 默认）下最常见的"隐形锁"问题。对账、批量更新、范围校验等场景一旦用了 `FOR UPDATE`，就会锁住区间内的所有空隙，导致其他事务无法插入新数据。表现为线上偶发的"插入卡住"或"锁等待超时"，排查时只看 EXPLAIN 看不出端倪，必须分析锁类型和隔离级别。
:::

## 问题分析

### bad.sql

```sql
-- 确认当前隔离级别（默认为 REPEATABLE-READ）
SELECT @@transaction_isolation;

BEGIN;

-- 范围查询加排他锁：RR 下锁定 user_id=100 的整个索引区间
SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;

-- 此时事务A持有 next-key lock，不 COMMIT，切换到会话B执行 INSERT 即可复现阻塞
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
| id | select_type | table   | partitions | type | possible_keys            | key              | key_len | ref         | rows | filtered | Extra       |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
|  1 | SIMPLE      | t_order | NULL       | ref  | idx_user_status          | idx_user_status  | 9       | const,const |    4 |   100.00 | Using where |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
```

### 为什么慢

单看 EXPLAIN，`type=ref`，`rows=4`，索引等值查找，执行计划完美。**问题不在 SQL 本身，而在 RR 隔离级别下的锁范围过大。**

RR 下 `SELECT ... WHERE user_id = 100 AND status = 1 FOR UPDATE` 在 `idx_user_status` 索引上加的是 **next-key lock**（记录锁 + 间隙锁）：

```
索引 idx_user_status 上的记录（user_id=100 的部分）：

  (100, 0)  (100, 0)  (100, 1)  (100, 1)  (100, 1)  (100, 1)  (100, 2)  (100, 3)
     |         |         |         |         |         |         |         |
   记录      记录      记录      记录      记录      记录      记录      记录

锁范围：
  - 记录锁：(100,1) 的 4 条记录
  - 间隙锁：(100,0) 到 (100,1) 之间的间隙
  - 间隙锁：(100,1) 到 (100,2) 之间的间隙
  - next-key lock = 记录锁 + 间隙锁

  实际锁定区间：(100,0] 到 (100,2) 的左开右开区间
```

插入阻塞时间线：

```
时间线   会话A（RR，加锁）                        会话B（被阻塞）
  T1     BEGIN;
  T2     SELECT ... WHERE user_id=100 AND status=1
         FOR UPDATE;
         -- 持有 (100,0] 到 (100,2) 的 next-key lock
  T3                                          BEGIN;
  T4                                          INSERT INTO t_order
                                              (order_no, user_id, amount, status)
                                              VALUES ('NO999999', 100, 99.00, 0);
                                              -- 新记录 (100, 0) 落在被锁间隙内
                                              -- 被阻塞！等待会话A释放锁
  T5     -- 不提交，保持锁
  T6                                          -- 等待... 直到 innodb_lock_wait_timeout
                                              -- ERROR 1205: Lock wait timeout exceeded
```

**为什么插入 `(100, 0)` 也被阻塞？** 虽然查询条件是 `status = 1`，但 next-key lock 锁定的是索引区间，不是查询条件。新插入的 `(100, 0)` 落在 `(100,0]` 到 `(100,2)` 的锁定区间内，因此被阻塞。即使插入 `(100, 2)` 或 `(100, 3)`，如果它们也落在锁定区间内，同样会被阻塞。

::: tip 核心认知
RR 下 `FOR UPDATE` 的锁范围远大于命中行数。它不只锁行，还锁间隙，目的是防幻读——但这会阻塞其他事务向间隙内插入数据。
:::

## 优化方案

### good.sql

```sql
-- 确认当前隔离级别（需先执行 setup-good.sql 切换到 RC）
SELECT @@transaction_isolation;

BEGIN;

-- 同样的查询，RC 下只锁命中的行，不锁间隙
SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;

-- 此时事务A只持有记录锁，切换到会话B执行 INSERT 不会被阻塞
```

配合 `setup-good.sql` 切换到 RC 隔离级别：

```sql
-- setup-good.sql: 切换到 READ COMMITTED 隔离级别
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

### 原理

RC（READ COMMITTED）隔离级别下，InnoDB 只加**记录锁**（Record Lock），不加**间隙锁**（Gap Lock），因此不会阻塞其他事务向间隙插入数据。

```
索引 idx_user_status 上的记录（user_id=100 的部分）：

  (100, 0)  (100, 0)  (100, 1)  (100, 1)  (100, 1)  (100, 1)  (100, 2)  (100, 3)
     |         |         |         |         |         |         |         |
   记录      记录      记录      记录      记录      记录      记录      记录

锁范围：
  - 记录锁：仅 (100,1) 的 4 条记录
  - 间隙锁：无

  实际锁定：仅 4 条匹配的记录
```

插入不被阻塞时间线：

```
时间线   会话A（RC，加锁）                        会话B（不受影响）
  T1     SET SESSION TRANSACTION ISOLATION
         LEVEL READ COMMITTED;
  T2     BEGIN;
  T3     SELECT ... WHERE user_id=100 AND status=1
         FOR UPDATE;
         -- 仅持有 (100,1) 的 4 条记录锁
  T4                                          BEGIN;
  T5                                          INSERT INTO t_order
                                              (order_no, user_id, amount, status)
                                              VALUES ('NO999999', 100, 99.00, 0);
                                              -- 新记录 (100, 0) 不在锁定范围内
                                              -- 插入成功！
  T6                                          COMMIT;
  T7     COMMIT;
         => 会话B 正常执行，不受会话A 影响
```

RC vs RR 锁行为对比：

| 场景 | RR（可重复读） | RC（读已提交） |
|------|---------------|---------------|
| 等值查询命中唯一索引 | 记录锁 | 记录锁 |
| 等值查询命中普通索引 | next-key lock | 记录锁 |
| 范围查询 | next-key lock | 记录锁 |
| 间隙锁 | 有 | 无 |
| 幻读 | 防止 | 可能出现 |

### 对比

| | bad.sql（RR） | good.sql（RC） |
|---|---|---|
| 隔离级别 | REPEATABLE-READ | READ-COMMITTED |
| 锁类型 | next-key lock（记录锁+间隙锁） | 仅记录锁 |
| 锁范围 | 索引区间（含间隙） | 仅命中的行 |
| 并发插入 | 被阻塞 | **不受影响** |
| 幻读 | 防止 | 可能出现 |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_user_status', rows: '4', Extra: 'Using where（next-key lock 阻塞插入）' }"
  :good="{ type: 'ref', key: 'idx_user_status', rows: '4', Extra: 'Using where（仅记录锁不阻塞）' }"
  improvement="消除间隙锁，并发插入不再阻塞，系统吞吐量显著提升"
/>

## 避坑指南

::: warning 注意事项

1. **高并发场景优先 RC**。RC 不加间隙锁，并发插入不受影响，死锁概率低。幻读由业务唯一索引或版本号兜底。

2. **RR 下避免范围 FOR UPDATE**。范围条件会加大量间隙锁，尽量用精确等值替代。如果必须范围查询，考虑先查 ID 列表再逐条 `FOR UPDATE`。

3. **RC 下需使用 ROW 格式 binlog**。RC 下如果 binlog 格式是 STATEMENT，可能导致主从数据不一致。确保 `binlog_format = 'ROW'`。

4. **幻读的权衡**。RC 允许幻读（同一事务内两次查询结果可能不同），大多数互联网应用可通过应用层逻辑规避。金融级一致性要求高的场景才需要使用 RR。

5. **8.0 可查锁详情**。`performance_schema.data_locks` 精确查看 `lock_mode` 判断是否有 GAP 锁。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| RR 间隙锁机制 | 有（默认行为） | 有（默认行为） |
| RC 消除间隙锁 | 有效 | 有效 |
| 锁信息查看 | `SHOW ENGINE INNODB STATUS` | `performance_schema.data_locks` 直观查看 lock_mode |
| 默认隔离级别 | RR | RR（需显式切换到 RC） |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 71-rc-vs-rr-isolation

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 71-rc-vs-rr-isolation --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 71-rc-vs-rr-isolation --no-seed
```
