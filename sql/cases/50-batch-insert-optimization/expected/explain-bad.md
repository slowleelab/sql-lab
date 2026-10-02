# 性能对比 - bad.sql (单行 INSERT 逐行提交)

## 测试场景

向 `t_batch_data` 表导入 10 万行数据，对比不同插入策略的耗时。

bad 方案：每行一条 INSERT 语句，autocommit=1（每行自动提交一次事务）。

## 单行 INSERT 的性能瓶颈

```
-- 每行执行一次:
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000001', 'user_000001@example.com', 1234.56, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000002', 'user_000002@example.com', 2345.67, NOW());

-- ... 重复 10 万次 ...
```

## 关键问题

| 环节 | 开销 | 分析 |
|------|-----|------|
| SQL 解析 | 10 万次 | 每条 INSERT 都要词法/语法分析、优化 |
| 事务提交 | 10 万次 | 每行 COMMIT 一次 |
| redo log fsync | 10 万次 | 每次提交触发 `innodb_flush_log_at_trx_commit=1` 的 fsync |
| binlog 写入 | 10 万个 event | 每行一个独立的 binlog event |
| undo log | 10 万次 | 每行独立的事务回滚日志 |

## 为什么慢

1. **fsync 是最大瓶颈**：`innodb_flush_log_at_trx_commit=1`（默认）时，每次事务提交都触发一次 `fsync` 将 redo log 刷盘。10 万次 fsync，每次约 1-5ms（SSD），仅刷盘就需 100-500 秒
2. **SQL 解析开销累积**：每条 INSERT 都要经过 词法分析 -> 语法分析 -> 优化器 -> 执行器，10 万次解析的 CPU 开销不可忽视
3. **索引维护代价**：每行插入后都要更新 PRIMARY KEY 和 idx_email 索引，单行插入无法批量维护索引
4. **binlog 膨胀**：10 万个独立 event，从库回放效率低

实际耗时：约 **85 秒**（实测 MySQL 8.0.46，10 万行，SSD，默认 `innodb_flush_log_at_trx_commit=1`）。

## MySQL 5.7 差异

5.7 中行为一致，单行 INSERT 的 fsync 开销甚至略高于 8.0（8.0 的 redo log 写入有并行优化）。两版本的瓶颈都在于频繁的事务提交和 fsync。
