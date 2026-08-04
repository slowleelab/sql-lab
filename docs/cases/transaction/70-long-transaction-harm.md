# 长事务危害

<CaseMeta difficulty="⭐⭐" category="事务" versions="5.7 & 8.0" :tags="['长事务', '锁持有', 'undo log', '外部调用']" />

## 支付接口 10 秒持锁：长事务拖垮连接池
电商支付系统中，扣减余额的流程是：先 `SELECT ... FOR UPDATE` 锁定账户，再调用外部支付接口完成扣款，最后 `UPDATE` 更新余额并提交事务。外部支付接口平均耗时 3~5 秒，高峰期甚至超过 10 秒。

```sql
BEGIN;
SELECT * FROM t_account WHERE id = 1 FOR UPDATE;  -- 加锁
-- 调用外部支付接口，耗时 5 秒...
UPDATE t_account SET balance = balance - 100 WHERE id = 1;
COMMIT;
```

结果：只要有一个用户发起支付，同一账户的其他操作（查询余额、转账、退款）全部被阻塞 5 秒以上。高峰期锁等待堆积，大量请求超时，系统吞吐量急剧下降。

::: warning 真实场景
这不是假设。任何涉及外部调用的业务（支付、短信通知、文件上传、RPC 调用），如果把外部调用放在数据库事务内，就会踩到长事务的坑。表现为线上偶发的"接口超时"或"锁等待超时"，排查时 EXPLAIN 看不出问题，必须分析事务边界和锁持有时间。
:::

## 问题分析

### bad.sql

```sql
BEGIN;

-- 第1步：加锁（排他锁，锁定 id=1）
SELECT * FROM t_account WHERE id = 1 FOR UPDATE;

-- 第2步：模拟耗时操作（如调用外部支付接口、发送短信通知等）
SELECT SLEEP(5);

-- 第3步：扣减余额
UPDATE t_account SET balance = balance - 100 WHERE id = 1;

COMMIT;
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT * FROM t_account WHERE id = 1 FOR UPDATE;
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | t_account | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

```
-- EXPLAIN UPDATE t_account SET balance = balance - 100 WHERE id = 1;
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_account | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

### 为什么慢

单看 EXPLAIN，`type=const`，`rows=1`，主键等值定位，执行计划完美。**问题不在 SQL 本身，而在事务边界过大，锁持有时间过长。**

```
时间线   会话A（长事务）                        会话B（被阻塞）
  T1     BEGIN;
  T2     SELECT ... WHERE id=1 FOR UPDATE;  -- 持有 id=1 排他锁
  T3     SELECT SLEEP(5);                   -- 模拟外部调用，耗时 5 秒
  T4                                          UPDATE ... WHERE id=1;
                                              -- 等待 id=1 锁（被A持有）
                                              -- 阻塞中... 等待 5 秒
  T5     UPDATE ... WHERE id=1;
  T6     COMMIT;                            -- 释放锁
  T7                                          获取锁，UPDATE 完成
         => 会话B 被阻塞约 5 秒
```

长事务的三大危害：

**1. 锁等待堆积** — 事务A 持有 id=1 的排他锁 5 秒，期间所有要修改 id=1 的事务全部排队等待。高并发下锁等待堆积，大量请求超时。

**2. undo log 膨胀** — 长事务期间，其他事务对表的修改产生的 undo log 无法被 purge（长事务的 ReadView 可能还需要读取旧版本数据）。undo log 不断累积，导致磁盘空间增长、MVCC 快照链过长、purge 线程压力增大。

**3. 主从延迟** — 长事务在从库回放时同样需要 5 秒，导致主从延迟加剧。如果长事务频繁出现，从库延迟会持续累积。

::: tip 核心认知
数据库事务应遵循"最小化"原则：事务内只做必须原子执行的操作，耗时操作（外部调用、复杂计算、文件 IO）一律移到事务外。
:::

## 优化方案

### good.sql

```sql
-- 第1步：先执行耗时操作（在事务外，不持有任何锁）
SELECT SLEEP(5);

-- 第2步：开启短事务，快速完成加锁 + 更新
BEGIN;

-- 加锁并校验（持锁时间仅毫秒级）
SELECT * FROM t_account WHERE id = 1 FOR UPDATE;

-- 扣减余额
UPDATE t_account SET balance = balance - 100 WHERE id = 1;

COMMIT;
```

### 原理

把耗时操作移到事务外，事务内只做必要的加锁 + 更新：

```
时间线   会话A（短事务）                        会话B（不受影响）
  T1     SELECT SLEEP(5);                   -- 事务外，不持有任何锁
  T2                                          UPDATE ... WHERE id=1;
                                              -- 正常执行，无阻塞
  T3     BEGIN;
  T4     SELECT ... WHERE id=1 FOR UPDATE;  -- 加锁（毫秒级）
  T5     UPDATE ... WHERE id=1;
  T6     COMMIT;                            -- 释放锁
         => 会话B 在 T2 时刻正常执行，不受会话A 影响
```

**核心优势**：
- 耗时操作在事务外执行，不持有任何锁
- 事务内只做加锁 + 更新，持锁时间从秒级降到毫秒级
- undo log 及时 purge，不会膨胀
- 主从延迟可控

### 对比

| | bad.sql（长事务） | good.sql（短事务） |
|---|---|---|
| 耗时操作位置 | 事务内（持锁期间） | 事务外（无锁） |
| 锁持有时间 | ~5000 ms | **~1 ms** |
| 并发阻塞 | 严重（5 秒） | **几乎无感知** |
| undo log | 持续膨胀 | **及时 purge** |
| 主从延迟 | +5 秒 | **无影响** |

<ExplainCompare
  :bad="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: 'Using where（锁持有 5 秒）' }"
  :good="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: 'Using where（锁持有 1 ms）' }"
  improvement="锁持有时间从 5000ms 降到 1ms，并发阻塞消除，undo log 及时 purge"
/>

## 避坑指南

::: warning 注意事项

1. **外部调用必须在事务外**。RPC 调用、HTTP 请求、文件 IO、短信通知等耗时操作一律在事务外执行。如果外部调用失败，由于尚未开启事务，无需回滚数据库，简化了异常处理逻辑。

2. **事务内只做必要操作**。事务内只做加锁 + 更新，不做任何耗时操作。如果需要在事务内校验外部调用结果，先在外部调用完成后记录结果，再在事务内校验。

3. **如需一致性保证，加乐观锁**。如果担心外部调用和事务之间的间隙数据被修改，可在事务内加 `version` 字段做乐观锁校验。

4. **监控长事务**。定期检查 `information_schema.INNODB_TRX`，找出 `trx_started` 时间过早的长事务并优化。

5. **Spring 事务陷阱**。`@Transactional` 注解的方法内如果包含外部调用，整个方法都在事务内。应将外部调用拆到事务方法外。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 长事务危害 | 存在 | 存在 |
| 锁信息查看 | `SHOW ENGINE INNODB STATUS` | `performance_schema.data_locks` 更直观 |
| undo log purge | 长事务阻塞 purge | 略有优化，但长事务仍是瓶颈 |
| 短事务优化 | 有效 | 有效 |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 70-long-transaction-harm

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 70-long-transaction-harm --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 70-long-transaction-harm --no-seed
```
