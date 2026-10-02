# EXPLAIN 参考结果 - bad.sql (RR 隔离级别，next-key lock 阻塞插入)

## MySQL 8.0（50 万行订单数据，RR 隔离级别）

```
-- EXPLAIN SELECT * FROM t_order WHERE user_id = 100 AND status = 1 FOR UPDATE;
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
| id | select_type | table   | partitions | type | possible_keys            | key              | key_len | ref         | rows | filtered | Extra       |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
|  1 | SIMPLE      | t_order | NULL       | ref  | idx_user_status          | idx_user_status  | 9       | const,const |    4 |   100.00 | Using where |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------------+------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 索引等值查找 |
| key | `idx_user_status` | 走 (user_id, status) 联合索引 |
| rows | ~4 | user_id=100 且 status=1 的订单约 4 行 |
| Extra | `Using where` | 索引精确匹配 |

执行计划本身没有问题，**问题出在 RR 隔离级别下的锁范围过大**。

## 为什么慢

### RR 下的锁范围（next-key lock）

在 RR 隔离级别下，`SELECT ... WHERE user_id = 100 AND status = 1 FOR UPDATE` 在 idx_user_status 索引上加锁：

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

### 插入阻塞时间线

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

### 锁信息查看

```sql
-- 8.0 查看锁信息
SELECT * FROM performance_schema.data_locks WHERE OBJECT_NAME = 't_order';
-- 显示会话A 持有 idx_user_status 上的 X 锁（next-key lock）

SELECT * FROM performance_schema.data_lock_waits;
-- 显示会话B 等待会话A 持有的锁
```

### 为什么插入 (100, 0) 也被阻塞

虽然查询条件是 `status = 1`，但 next-key lock 锁定的是索引区间，不是查询条件。新插入的 `(100, 0)` 落在 `(100,0]` 到 `(100,2)` 的锁定区间内，因此被阻塞。

即使插入 `(100, 2)` 或 `(100, 3)`，如果它们也落在锁定区间内，同样会被阻塞。

## 量化影响

| 指标 | RR（next-key lock） | RC（仅记录锁） |
|------|---------------------|---------------|
| 锁范围 | 索引区间（含间隙） | 仅命中的行 |
| 并发插入 | 被阻塞 | 不受影响 |
| 锁等待超时 | 常见 | 极少 |
| 系统吞吐量 | 低 | 高 |

## 5.7 vs 8.0 差异

- RR 和 RC 的锁行为在两个版本中一致
- 8.0 的 `performance_schema.data_locks` 可更清晰地查看 next-key lock 范围
- 8.0 默认隔离级别仍是 RR，需显式切换到 RC
