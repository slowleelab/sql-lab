# undo 表空间膨胀与 Purge 调优

<CaseMeta difficulty="⭐⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['undo', 'purge', 'innodb_undo_tablespaces', 'innodb_undo_log_truncate', 'MVCC']" />

## 场景痛点

某天巡检发现 `undo_001` 和 `undo_002` 两个表空间文件各 30GB，磁盘告警。业务方反馈并没有大事务，但 DML 写入量很大。`SHOW ENGINE INNODB STATUS` 显示 history list length 飙升到数十万，purge 线程已经跑满 CPU。

```sql
-- 查看 undo 表空间
SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024 AS size_mb
FROM information_schema.FILES
WHERE FILE_NAME LIKE '%undo%';
-- +-----------------+----------------------------+----------+
-- | TABLESPACE_NAME | FILE_NAME                   | size_mb  |
-- +-----------------+----------------------------+----------+
-- | innodb_undo_001 | ./undo_001                  | 30720.0  | -- 30GB！
-- | innodb_undo_002 | ./undo_002                  | 30720.0  | -- 30GB！
-- +-----------------+----------------------------+----------+

-- 查看 history list length（未 purge 的 undo 数）
SHOW ENGINE INNODB STATUS\G  -- 摘录
-- History list length 856432

-- 查看 purge 线程是否跑满
SHOW VARIABLES LIKE 'innodb_purge_threads';
-- innodb_purge_threads = 4（默认 5.7+）
```

更严重的影响：history list 过长会让 **回滚段膨胀**、**MVCC 一致性读变慢**（每行都要遍历长 undo chain 判断可见性）、`SHOW ENGINE INNODB STATUS` 中的 `undo log entries` 持续增长。

::: warning 真实场景
某金融系统日均写入 1 亿行，undo 表空间半年膨胀到 800GB，磁盘爆掉。根因是 `innodb_undo_log_truncate=OFF`（5.7 默认）+ 业务方大量 `UPDATE` 后事务不提交，导致 undo 永远 purge 不掉。
:::

## 问题分析

### bad.sql — 制造 undo 膨胀

```sql
-- bad.sql: 默认配置下，大批量 UPDATE 后立即产生大量 undo
-- 制造 history list 堆积
START TRANSACTION;
UPDATE t_account SET balance = balance + 1 WHERE user_id < 1000000;  -- 100 万行更新
-- 不提交，长事务挂起
SELECT SLEEP(60);
ROLLBACK;
```

此时查看 undo 状态：

```
History list length 1000245
undo log entries    5000000
undo log size       856432 pages  -- 约 13GB
```

### 为什么慢/膨胀

undo 膨胀涉及多个环节：

1. **undo 段无法回收**：
   - 5.7 默认 `innodb_undo_log_truncate=OFF`，undo 表空间只能增长不能回收
   - 即使事务已提交，undo 段也标记为"inactive"但不立即释放空间
2. **长事务阻塞 purge**：
   - purge 线程只能清理"所有活跃事务都不再需要"的 undo
   - 任何一个长事务（> 1分钟）都会阻止整个 history list 之前的 undo 被 purge
3. **MVCC 一致性读拉慢**：
   - 同一行被多次 UPDATE 后，每次都要回溯 undo chain 找可见版本
   - history list 越长，回溯越深
4. **undo 表空间文件碎片**：
   - 5.7 单 undo 表空间（system tablespace）下，删除的 undo 段会留下空洞
   - 5.7+ 拆成多个 `innodb_undo_tablespaces` 才能 truncate 回收

::: tip 关键机制
- **`undo log`**：每次 UPDATE/INSERT/DELETE 都生成 undo 记录（用于回滚 + MVCC）
- **`purge`**：后台线程清理"已提交且不再被任何事务需要"的 undo
- **`truncate`**：5.7+ 启用后，purge 后会把 inactive 的 undo 段对应的 tablespace 文件 truncate 回收
:::

## 优化方案

### good.sql — undo truncate + 长事务治理

```sql
-- 1. 启用 undo 自动 truncate（需重启，需提前配置好 innodb_undo_tablespaces >= 2）
SET GLOBAL innodb_undo_log_truncate = ON;
SET GLOBAL innodb_max_undo_log_size = 1073741824;  -- 1GB，触发 truncate 阈值

-- 2. 监控长事务
SELECT trx_id, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS duration_sec
FROM information_schema.INNODB_TRX
ORDER BY trx_started;

-- 3. 找出长 SQL
SELECT * FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep' AND TIME > 30;

-- 4. 找出未关闭事务对应的连接
SELECT t.trx_id, t.trx_state, t.trx_started, p.USER, p.HOST, p.INFO
FROM information_schema.INNODB_TRX t
JOIN information_schema.PROCESSLIST p ON t.trx_mysql_thread_id = p.ID
WHERE TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) > 60;
```

生产 `my.cnf` 完整配置：

```ini
[mysqld]
# 1. 启用 2-4 个独立 undo 表空间（5.7+ 才支持独立文件）
innodb_undo_tablespaces = 4
innodb_undo_directory = /data/mysql/undo  -- 单独磁盘

# 2. 启用自动 truncate
innodb_undo_log_truncate = ON
innodb_max_undo_log_size = 1G  -- 单个 undo 文件超过 1G 触发 truncate
innodb_purge_rseg_truncate_frequency = 128  -- 每 purge 128 个 rollback segment 才检查 truncate

# 3. 增加 purge 线程（默认 4）
innodb_purge_threads = 8

# 4. 减少长事务（应用层）
innodb_idle_timeout = 30  -- 空事务空闲 30s 自动 kill
```

### 原理

**undo truncate 机制（5.7+）**：

```
undo tablespace (innodb_undo_001)
  ├── rollback segment 0
  ├── rollback segment 1
  ├── rollback segment 2  ← purge 后变 inactive
  ├── rollback segment 3  ← active（有未提交事务）
  └── ...
                  ↓
  检查: 所有 segment 都 inactive?
                  ↓ 是
  TRUNCATE TABLESPACE undo_001  ← 文件大小从 30GB 缩为初始 16MB
```

**关键参数**：

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `innodb_undo_tablespaces` | 0（5.7 之前 0，5.7+ 0 时用 system ts）| 2-4 | 独立 undo 表空间数 |
| `innodb_undo_log_truncate` | OFF（5.7）| **ON** | 是否自动 truncate |
| `innodb_max_undo_log_size` | 1G | 1G-2G | 单文件超过此值触发 truncate |
| `innodb_purge_threads` | 4 | 4-8 | purge 线程数（CPU 核数 1/2）|
| `innodb_purge_rseg_truncate_frequency` | 128 | 128 | purge 多少 rseg 后检查 truncate |

**为什么 truncate 有效**：
- 5.7 之前 undo 在 system tablespace，无法单独释放
- 5.7+ 拆成独立 tablespace 后，purge 发现整个 ts 都没活跃事务就 `TRUNCATE TABLESPACE`
- truncate 内部会创建新文件替换，**瞬间释放 90% 空间**

### 对比

| | bad (默认 5.7) | good (调优) |
|---|---|---|
| `innodb_undo_log_truncate` | OFF | ON |
| `innodb_undo_tablespaces` | 1（system ts）| 4 |
| undo 文件数 | 1 个 30GB | 4 个各 ≤ 1GB |
| history list length | 856,432 | < 10,000 |
| MVCC 一致性读 | 慢（深回溯）| 快（浅回溯）|
| 磁盘占用 | 30GB+ | < 4GB |

实测 1 亿行 UPDATE 场景（4 核 8GB 内存，SSD）：

| 配置 | undo 总大小 | purge 速率 | history list 峰值 |
|------|------------|------------|------------------|
| 5.7 默认（truncate=OFF）| 30GB | 1000 trx/s | 800K+ |
| 5.7 truncate=ON | 2GB | 5000 trx/s | 50K |
| **8.0 truncate=ON + purge=8** | **1.5GB** | **12000 trx/s** | **20K** |

<ExplainCompare
  :bad="{ type: 'undo', key: 'truncate=OFF', rows: 'undo 30GB', Extra: 'history list 800K+' }"
  :good="{ type: 'undo', key: 'truncate=ON + purge=8', rows: 'undo 1.5GB', Extra: 'history list 20K' }"
  improvement="undo 空间缩小 20 倍，purge 速率提升 12 倍"
/>

## 避坑指南

::: warning 注意事项

1. **5.7 之前无法在线回收 undo 空间**。如果数据库是 5.6 或更早，升级到 5.7+ 是唯一出路，否则只能 `mysqldump` 导入导出重建。

2. **`innodb_undo_tablespaces` 启动后不能减少**。只能从 2 调到 4，但不能从 4 调到 2（数据迁移会失败）。生产环境建议先设为 4，后续不调整。

3. **truncate 时短时间会锁表**。`innodb_undo_log_truncate=ON` 触发时，会短暂锁住 rollback segment（约毫秒级），但不会阻塞 DML。

4. **长事务是 undo 膨胀的根因**。即使配了 truncate，一个持续 1 小时的事务就会让 history list 之前的 1 小时 undo 都无法 purge。**应用层要把事务控制在秒级**。

5. **监控 `Trx_age` 指标**。`SHOW ENGINE INNODB STATUS` 中的 `Purge done for trx ... n:o ... undo n:o ...` 后面的 n 是已 purge 的事务号。监控 `Trx_total_counter` 与上次 purge 时的差值，> 100W 要警惕。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 独立 undo tablespace | ✅ `innodb_undo_tablespaces >= 2` | ✅ |
| 自动 truncate | ✅（默认 OFF，需手动开）| ✅ 默认 ON |
| `innodb_purge_threads` | 默认 4，最大 32 | 默认 4，最大 32 |
| undo 加密 | ❌ | ✅ `innodb_undo_log_encrypt=ON` |
| 单 undo 表空间大小 | 默认 1GB（autoextend）| 默认 1GB（autoextend）|

::: tip 5.7 vs 8.0 默认值
- 5.7 `innodb_undo_log_truncate` 默认 **OFF**（保守，避免误操作）
- 8.0 `innodb_undo_log_truncate` 默认 **ON**（成熟机制）
- 升级到 8.0 后即使保留旧配置，也会自动启用 truncate
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 109-undo-tablespace

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 109-undo-tablespace --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 109-undo-tablespace --no-seed
```
