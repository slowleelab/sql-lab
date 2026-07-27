# 大表批量 INSERT 优化

<CaseMeta difficulty="⭐⭐" category="DDL与大表" versions="5.7 & 8.0" :tags="['批量插入', 'INSERT优化', '事务提交', 'LOAD DATA']" />

## 场景痛点

数据迁移脚本需要导入 10 万行数据到 `t_batch_data` 表。开发同学用 ORM 框架的默认 `save()` 方法逐行插入，每行一个事务，跑了 **85 秒**还没完成：

```sql
-- 每行一条 INSERT，autocommit=1，每行自动提交一次事务
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000001', 'user_000001@example.com', 1234.56, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000002', 'user_000002@example.com', 2345.67, NOW());

-- ... 重复 10 万次 ...
```

10 万行数据导入 85 秒，磁盘 I/O 占满，数据库响应变慢。问题出在**每行一个事务**--10 万次 `fsync` 刷盘成了性能瓶颈。

::: warning 真实场景
数据迁移、日志导入、CSV 数据加载、ORM 框架批量保存--凡是逐行 INSERT 的场景都可能踩到。很多 ORM 框架的默认 `save()` 就是逐行提交，开发同学不感知底层的事务行为，直到导入慢到告警。
:::

## 问题分析

### bad.sql

```sql
-- 单行 INSERT 循环（每行一个事务）
--
-- 1. 每条 INSERT 是独立事务（autocommit=1 时自动提交）
-- 2. 每次提交都要:
--    - 写 undo log（事务回滚日志）
--    - 写 redo log（WAL，fsync 刷盘）
--    - 更新 binlog（如开启）
-- 3. 10 万次提交 = 10 万次 fsync，磁盘 I/O 是瓶颈
-- 4. 每行单独解析 SQL、优化、执行，解析开销累积

-- 单行插入示例（autocommit=1，每行自动提交一次事务）
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000001', 'user_000001@example.com', 1234.56, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000002', 'user_000002@example.com', 2345.67, NOW());

INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES ('user_000003', 'user_000003@example.com', 3456.78, NOW());

-- ... 重复 10 万次，每次一条 INSERT ...
```

### 性能瓶颈分析

本案例的性能对比不是 EXPLAIN 执行计划（INSERT 不产生 EXPLAIN），而是**实际导入耗时**。单行 INSERT 的性能瓶颈在每个环节都被放大 10 万倍：

| 环节 | 开销 | 分析 |
|------|-----|------|
| SQL 解析 | 10 万次 | 每条 INSERT 都要词法/语法分析、优化 |
| 事务提交 | 10 万次 | 每行 COMMIT 一次 |
| redo log fsync | 10 万次 | 每次提交触发 `innodb_flush_log_at_trx_commit=1` 的 fsync |
| binlog 写入 | 10 万个 event | 每行一个独立的 binlog event |
| undo log | 10 万次 | 每行独立的事务回滚日志 |

### 为什么慢

1. **fsync 是最大瓶颈**：`innodb_flush_log_at_trx_commit=1`（默认）时，每次事务提交都触发一次 `fsync` 将 redo log 刷盘。10 万次 fsync，每次约 1-5ms（SSD），仅刷盘就需 100-500 秒
2. **SQL 解析开销累积**：每条 INSERT 都要经过 词法分析 -> 语法分析 -> 优化器 -> 执行器，10 万次解析的 CPU 开销不可忽视
3. **索引维护代价**：每行插入后都要更新 PRIMARY KEY 和 `idx_email` 索引，单行插入无法批量维护索引
4. **binlog 膨胀**：10 万个独立 event，从库回放效率低

实际耗时：约 **85 秒**（实测 MySQL 8.0.46，10 万行，SSD，默认 `innodb_flush_log_at_trx_commit=1`）。

::: tip 核心认知
INSERT 的代价不只是"插多少行"，而是"提交多少次事务"。每次事务提交都触发 fsync 刷盘，10 万次提交 = 10 万次磁盘 I/O。批量插入的本质是减少提交次数和解析次数。
:::

## 优化方案

### setup-good.sql（可选前置准备）

`setup-good.sql` 提供了导入期间的 session 参数优化（默认注释，按需开启）：

```sql
-- 临时关闭 unique_checks 和 foreign_key_checks（仅适用于无外键约束的导入）
-- SET unique_checks = 0;
-- SET foreign_key_checks = 0;

-- 调整 innodb_flush_log_at_trx_commit（导入期间，降低 fsync 频率）
-- 0: 每秒刷盘（崩溃可能丢 1 秒数据）
-- 1: 每次提交刷盘（默认，最安全）
-- 2: 每次提交写 OS buffer，每秒刷盘（折中）
-- SET GLOBAL innodb_flush_log_at_trx_commit = 2;

-- 导入完成后恢复:
-- SET unique_checks = 1;
-- SET foreign_key_checks = 1;
-- SET GLOBAL innodb_flush_log_at_trx_commit = 1;
```

### good.sql

```sql
-- 批量 INSERT + 事务批量提交
--
-- 1. 多行 VALUES 合并为一条 INSERT，减少 SQL 解析次数
-- 2. 关闭 autocommit，手动控制事务，批量提交
--    每 5000 行 COMMIT 一次，而非每行提交
-- 3. 10 万行 / 5000 = 20 次提交（vs bad 的 10 万次提交）

-- 多行批量 INSERT 示例（一条语句插入多行）
INSERT INTO t_batch_data (user_name, email, amount, created_at)
VALUES
    ('user_100001', 'user_100001@example.com', 1234.56, NOW()),
    ('user_100002', 'user_100002@example.com', 2345.67, NOW()),
    ('user_100003', 'user_100003@example.com', 3456.78, NOW()),
    ('user_100004', 'user_100004@example.com', 4567.89, NOW()),
    ('user_100005', 'user_100005@example.com', 5678.90, NOW());
-- ... 每批 5000 行，共 20 批 ...
```

批量插入的存储过程实现（关闭 autocommit，每 5000 行提交一次）：

```sql
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_good_insert $$
CREATE PROCEDURE sp_good_insert()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;  -- 关闭自动提交

    WHILE i < 100000 DO
        INSERT INTO t_batch_data (user_name, email, amount, created_at)
        VALUES (
            CONCAT('user_', LPAD(i, 6, '0')),
            CONCAT('user_', LPAD(i, 6, '0'), '@example.com'),
            ROUND(1 + RAND() * 9999, 2),
            NOW()
        );
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;  -- 每 5000 行提交一次
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;
```

### 原理

1. **减少 fsync 次数**：10 万行 / 5000 = 20 次提交，仅 20 次 fsync（vs bad 的 10 万次）
2. **减少 SQL 解析**：多行 VALUES 合并，一条语句插入多行，解析次数大幅降低
3. **批量索引维护**：InnoDB 在批量插入时可以更高效地维护 B+ 树索引，减少页分裂
4. **redo log 批量写**：一个事务内的多次插入共享同一批 redo log 写入，效率更高

### 对比

| | bad.sql (单行) | good.sql (批量) | LOAD DATA |
|---|---|---|---|
| 耗时 | ~85 秒 | **~6 秒** | ~2 秒 |
| 事务提交次数 | 100,000 | **20** | 1 |
| SQL 解析次数 | 100,000 | **20** | 1 |
| fsync 次数 | 100,000 | **20** | 1 |
| binlog event | 100,000 | **20** | 1 |

<ExplainCompare
  :bad="{ type: '单行 INSERT', key: 'autocommit=1', rows: '10万次提交', Extra: '10万次 fsync' }"
  :good="{ type: '批量 INSERT', key: 'autocommit=0 + 每5000行COMMIT', rows: '20次提交', Extra: '20次 fsync' }"
  improvement="提交次数从 10 万降到 20，耗时从 85 秒降到 6 秒，提升约 14 倍"
/>

### 进阶：LOAD DATA INFILE（最快方式）

百万行以上的超大数据集，优先用 `LOAD DATA INFILE`，比批量 INSERT 再快 3-5 倍：

```sql
SET autocommit = 0;
LOAD DATA INFILE '/path/to/data.csv'
INTO TABLE t_batch_data
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
(user_name, email, amount, created_at);
COMMIT;
```

耗时约 **2 秒**（10 万行）。因为单次事务、一次提交、批量解析、顺序写入最小化索引维护开销。

## 避坑指南

::: warning 注意事项

1. **batch size 选择要适中**。推荐 5000-10000 行/批。过小则提交次数多，过大则单事务 undo log 膨胀、锁持有时间长。

2. **ORM 框架配置 batch_size**。使用 Hibernate 的 `hibernate.jdbc.batch_size`、MyBatis 的批量 executor 等，避免逐行 save + commit 的默认行为。

3. **超大数据集用 LOAD DATA**。百万行以上优先用 `LOAD DATA INFILE`，比批量 INSERT 再快 3-5 倍。

4. **导入后重建索引**。如果导入前可以先删非唯一索引，导入后再 `CREATE INDEX`，减少索引维护开销。

5. **关闭安全检查（导入期间）**。临时关闭 `unique_checks` / `foreign_key_checks`，导入后恢复。降低 fsync 频率（`innodb_flush_log_at_trx_commit=2`）可提升 2-3 倍，但需权衡数据安全。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 批量 INSERT + 事务提交 | ✅ 有效 | ✅ 有效 |
| redo log 写入 | 串行 | 并行优化，略快 |
| 自适应参数 | 手动调优 | `innodb_dedicated_server` 自适应 |
| LOAD DATA INFILE | ✅ 支持 | ✅ 支持 |

::: tip 8.0 redo log 优化
8.0 的 redo log 写入有并行优化，批量插入略快于 5.7。8.0 还支持 `innodb_dedicated_server` 自适应参数，大内存场景批量插入更优。但两版本的优化原理一致，good 方案在两个版本上都有效。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 46-batch-insert-optimization

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 46-batch-insert-optimization --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 46-batch-insert-optimization --no-seed
```
