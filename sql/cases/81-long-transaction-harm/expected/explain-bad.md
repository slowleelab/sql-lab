# EXPLAIN 参考结果 - bad.sql (长事务持锁 5 秒)

## MySQL 8.0（10 万行账户数据）

长事务问题无法通过单条 EXPLAIN 完整展示，需结合锁等待和 undo log 分析。

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

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 主键等值定位，单行操作本身极快 |
| key | `PRIMARY` | 走主键索引 |
| rows | 1 | 只命中 1 行 |
| Extra | `Using where` | WHERE id=1 精确定位 |

单条 SQL 执行计划没有问题，**问题出在事务边界过大，锁持有时间过长**。

## 为什么慢

### 长事务时间线

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

### 长事务的三大危害

**1. 锁等待堆积**

```
-- 会话B 执行时的锁等待状态
SELECT * FROM performance_schema.data_lock_waits;
-- 显示会话B 等待会话A 持有的 t_account.id=1 记录锁

SELECT * FROM performance_schema.data_locks WHERE OBJECT_NAME = 't_account';
-- 显示会话A 持有 id=1 的 X 锁（排他锁）
```

**2. undo log 膨胀**

长事务期间，其他事务对表的修改产生的 undo log 无法被 purge（因为长事务的 ReadView 可能还需要读取旧版本数据）。undo log 不断累积，导致：
- 磁盘空间占用增长
- MVCC 快照链过长，查询需要遍历更多版本
- purge 线程压力增大

```sql
-- 查看 undo log 使用情况
SELECT * FROM information_schema.INNODB_TRX\G
-- trx_started 显示事务开始时间，trx_rows_locked 显示锁定行数
```

**3. 主从延迟**

长事务在从库回放时同样需要 5 秒，导致主从延迟加剧。如果长事务频繁出现，从库延迟会持续累积。

## 量化影响

| 指标 | 短事务（毫秒级） | 长事务（5 秒） |
|------|-----------------|---------------|
| 锁持有时间 | ~1 ms | ~5000 ms |
| 并发事务等待 | 几乎无感知 | 阻塞 5 秒 |
| undo log 累积 | 及时 purge | 持续膨胀 |
| 主从延迟 | 无影响 | 增加 5 秒 |
| 系统吞吐量 | 高 | 急剧下降 |

## 5.7 vs 8.0 差异

- 长事务危害在两个版本中表现一致
- 8.0 的 `performance_schema.data_locks` 可更方便地监控锁持有情况
- 8.0 的 undo log purge 机制略有优化，但长事务仍是主要瓶颈
