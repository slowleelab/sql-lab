# EXPLAIN 参考结果 - bad.sql (反向加锁导致死锁)

## MySQL 8.0（10 万行订单数据）

死锁场景无法用单条 EXPLAIN 完整展示，需结合两条 UPDATE 的执行计划与锁等待分析。

```
-- EXPLAIN UPDATE t_order_deadlock SET ... WHERE id = 1;
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_order_deadlock  | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

```
-- EXPLAIN UPDATE t_order_deadlock SET ... WHERE id = 2;
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_order_deadlock  | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 主键等值定位，单行更新本身极快 |
| key | `PRIMARY` | 走主键索引 |
| rows | 1 | 每条 UPDATE 只命中 1 行 |
| Extra | `Using where` | WHERE id=N 精确定位 |

单条 UPDATE 性能没有问题，**问题出在两个事务的加锁顺序不一致**。

## 为什么会死锁

### 死锁复现步骤（需两个会话）

```
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

### 锁等待图

```
  事务A ──持有──> 锁 id=1 ──等待──> 锁 id=2 <──持有── 事务B
     ^                                                 |
     └──────────────── 循环等待 ────────────────────────┘
```

### 加锁分析（RR 隔离级别）

- UPDATE `WHERE id=1`（主键唯一索引等值）：加 **记录锁（Record Lock）** 在 id=1
- RR 下等值更新命中唯一索引为记录锁；若命中普通索引或范围条件则可能为 **next-key lock**（记录锁 + 间隙锁）
- 死锁本质是两个事务持有对方需要的锁，同时等待对方持有的锁

## 死锁排查命令

```sql
-- 1. 查看最近一次死锁详情（需开启 innodb_print_all_deadlocks 才记录全部）
SHOW ENGINE INNODB STATUS\G
-- 在 LATEST DETECTED DEADLOCK 段查看：
--   TRANSACTION 事务A, holds lock, waits for lock
--   TRANSACTION 事务B, holds lock, waits for lock
--   WE ROLL BACK TRANSACTION (事务B)

-- 2. 开启全部死锁日志（记录到 error log）
SET GLOBAL innodb_print_all_deadlocks = ON;

-- 3. 查看当前锁等待
SELECT * FROM performance_schema.data_locks;        -- 8.0
SELECT * FROM performance_schema.data_lock_waits;   -- 8.0

-- 4. 查看隔离级别
SELECT @@transaction_isolation;
```

## 5.7 vs 8.0 差异

- 死锁检测机制一致，InnoDB 均会自动回滚 victim 事务
- 8.0 提供了 `performance_schema.data_locks` 可直接查看锁信息；5.7 需依赖 `SHOW ENGINE INNODB STATUS`
- 8.0 默认开启死锁检测 `innodb_deadlock_detect=ON`，高并发下可考虑关闭以降低检测开销（但需配合超时机制）
