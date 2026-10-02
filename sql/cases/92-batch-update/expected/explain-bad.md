# EXPLAIN 参考结果 - bad.sql (一次性 UPDATE 50 万行)

## MySQL 8.0（100 万行订单数据，约 50 万行待更新）

```
-- EXPLAIN UPDATE t_order SET status = 3 WHERE status = 2 AND created_at < '2026-01-01';
+----+-------------+---------+------------+-------+--------------------------+------------------+---------+------+--------+----------+-------------+
| id | select_type | table   | partitions | type  | possible_keys            | key              | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+---------+------------+-------+--------------------------+------------------+---------+------+--------+----------+-------------+
|  1 | UPDATE      | t_order | NULL       | range | idx_status_created       | idx_status_created | 6     | NULL | 499830 |   100.00 | Using where |
+----+-------------+---------+------------+-------+--------------------------+------------------+---------+------+--------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 索引范围扫描 |
| key | `idx_status_created` | 走 (status, created_at) 联合索引 |
| rows | ~499,830 | 匹配约 50 万行 |
| Extra | `Using where` | 索引过滤 |

执行计划本身没有问题（走了索引），**问题出在一次性更新 50 万行的锁和日志开销**。

## 为什么慢

### 一次性 UPDATE 的执行流程

1. 通过 `idx_status_created` 索引扫描 `status=2 AND created_at < '2026-01-01'` 的约 50 万行
2. 对每行加记录锁（X 锁）
3. 生成每行的 undo log（修改前的镜像）
4. 更新每行的 status 字段
5. 事务提交，释放 50 万行锁

**问题**：
- 锁定 50 万行，锁持有时间长（秒级甚至分钟级）
- 生成 50 万条 undo log，undo 表空间膨胀
- 长事务导致 purge 线程无法清理 undo log
- 主从延迟加剧（从库回放同样耗时）

### 锁等待影响

```
时间线   会话A（大批量 UPDATE）                  会话B（被阻塞）
  T1     BEGIN;
  T2     UPDATE t_order SET status=3
         WHERE status=2 AND created_at < '2026-01-01';
         -- 锁定 50 万行，持续 30 秒
  T3                                          UPDATE t_order SET amount=100
                                              WHERE id = 500000;
                                              -- id=500000 在锁定范围内
                                              -- 被阻塞！等待 30 秒
  T4     COMMIT;                            -- 释放 50 万行锁
  T5                                          获取锁，UPDATE 完成
         => 会话B 被阻塞约 30 秒
```

### undo log 膨胀

```sql
-- 查看 undo log 使用情况
SELECT * FROM information_schema.INNODB_TRX\G
-- trx_rows_locked: 500000（锁定 50 万行）
-- trx_rows_modified: 500000（修改 50 万行）

-- 查看 undo 表空间
SELECT * FROM information_schema.INNODB_TABLESPACES WHERE NAME LIKE '%undo%';
-- undo 表空间持续增长，无法 purge
```

### 主从延迟

一次性 UPDATE 50 万行在主库执行 30 秒，从库回放同样需要 30 秒。如果期间有其他写入，从库延迟会持续累积。

实际耗时：
- 一次性 UPDATE：约 **30 秒**（50 万行锁定 + 更新 + undo log）

## 5.7 vs 8.0 差异

- 大批量 UPDATE 的锁和日志问题在两个版本中一致
- 8.0 的 undo log 管理略有优化，但 50 万行更新仍是长事务
- 8.0 的 `performance_schema.data_locks` 可查看锁定的行数
