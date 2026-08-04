# TiDB 事务模型——乐观事务 vs 悲观事务

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['事务', '乐观锁', '悲观锁', 'Write Conflict', '重试']" />

## 9007重复：重复、余额不一致等数据问题
应用从 MySQL 迁移到 TiDB 后，偶发报错 `ERROR 9007 (HY000): Write conflict` 或 `Information schema is changed`，业务侧出现订单重复、余额不一致等数据问题。排查发现迁移后未设置 `tidb_txn_mode`，默认行为与预期不符——早期 TiDB 默认乐观事务，TiDB 6.0+ 默认悲观事务，中间版本升级可能导致行为突变。

```sql
-- 乐观事务模式下：两个会话同时修改同一行
-- 会话A
SET SESSION tidb_txn_mode = 'optimistic';
BEGIN;
UPDATE t_account SET balance = balance - 1000 WHERE id = 1;
-- 此时不持锁，其他事务可同时写入

-- 会话B（同时执行）
SET SESSION tidb_txn_mode = 'optimistic';
BEGIN;
UPDATE t_account SET balance = balance - 500 WHERE id = 1;
COMMIT;  -- 事务B先提交成功

-- 回到会话A
COMMIT;  -- ❌ Write Conflict! 事务A提交失败
```

::: warning 真实场景
余额扣减、库存扣减、订单状态变更——这些"写后读"场景是 Write Conflict 的高发区。乐观事务在提交阶段才检测冲突，提交失败意味着整个事务白做；悲观事务在写入时加锁，与经典 MySQL 行为一致。了解两种模式的差异与选择策略，是从 MySQL 平滑迁移到 TiDB 的核心前置知识。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 乐观事务模式下的 Write Conflict

-- 设置乐观事务模式
SET SESSION tidb_txn_mode = 'optimistic';

-- 事务A (模拟第一个会话)
BEGIN;
UPDATE t_account SET balance = balance - 1000 WHERE id = 1;
-- 此时不持有锁，其他事务可以同时修改同一行

-- 事务B (模拟第二个会话——在另一个终端执行)
-- BEGIN;
-- UPDATE t_account SET balance = balance - 500 WHERE id = 1;  -- 乐观模式下不会阻塞
-- COMMIT;  -- 事务B先提交成功

-- 回到事务A
-- COMMIT;  -- Write Conflict! 事务A的提交被拒绝，需要客户端重试

-- 查看乐观事务的重试限制
SHOW VARIABLES LIKE 'tidb_retry_limit';

-- 查看当前事务模式
SELECT @@tidb_txn_mode;
```

### 为什么会出现 Write Conflict

```
乐观事务的执行时间线：

时间线   事务A                            事务B
  T1     BEGIN;                           BEGIN;
  T2     UPDATE id=1 (本地缓存写入)         UPDATE id=1 (本地缓存写入)
  T3                                       COMMIT;  ← 先到 TiKV Prewrite
  T4     COMMIT;  ← ❌ Prewrite 阶段检测到
           id=1 版本已被事务B修改          → Write Conflict!
         → 事务A 被拒绝
```

乐观事务基于 TiKV 的 Percolator 模型：
- 事务执行期间，所有写入缓存在 TiDB 内存中，不写 TiKV
- Prewrite 阶段对比 `start_ts` 版本号与行当前最新版本
- 若发现冲突（行已被其他事务修改），整个事务失败

**冲突检测在提交阶段，而非写入阶段——这是乐观事务 Write Conflict 的根因。**

```
乐观事务 vs 悲观事务冲突处理对比：

        乐观事务                      悲观事务
写入时   无锁，不检查冲突              加锁，冲突则等待
提交时   Prewrite 检测冲突             直接提交（锁已保证无冲突）
冲突     Write Conflict 报错           锁等待超时报错
恢复     客户端重试整个事务             自动获取锁后继续
```

| 维度 | 乐观事务（bad） | 悲观事务（good） |
|------|----------------|-----------------|
| 写入时 | **无锁** | 加锁（行级） |
| 冲突处理 | 提交时检测，失败重试 | 写入时等待/超时 |
| 并发写入同一行 | 不会阻塞，但先提交者胜 | 串行执行 |
| 死锁风险 | 极低 | 低（TiDB 有死锁检测） |
| 客户端复杂度 | 需实现重试逻辑 | 无需特殊处理 |
| 适合场景 | 低冲突 + 高并发 | 高冲突 OLTP |

## 优化方案

### good.sql

```sql
-- good.sql: 悲观事务模式——与 MySQL 行为一致

-- 设置悲观事务模式（TiDB 6.0+ 默认）
SET SESSION tidb_txn_mode = 'pessimistic';

-- 事务A (模拟第一个会话)
BEGIN;
UPDATE t_account SET balance = balance - 1000 WHERE id = 1;
-- 悲观模式下此行已被锁定，其他事务必须等待

-- 事务B (模拟第二个会话——在另一个终端执行)
-- BEGIN;
-- UPDATE t_account SET balance = balance - 500 WHERE id = 1;  
-- 阻塞等待事务A释放锁（默认 innodb_lock_wait_timeout = 50s）
-- COMMIT;

-- 事务A提交后事务B继续执行
-- COMMIT;  -- 成功

-- 事务选择对比
SELECT '悲观事务' AS mode, '写入时加锁，提交即成功' AS behavior
UNION ALL
SELECT '乐观事务', '提交时检测冲突，失败需重试';

-- AS OF TIMESTAMP 历史读（TiDB 特有功能）
SELECT @@tidb_snapshot;
-- SET @@tidb_snapshot = '2026-07-01 00:00:00';
-- SELECT * FROM t_account;  -- 读取历史快照
-- SET @@tidb_snapshot = '';
```

### 原理

悲观事务在 DML 执行阶段就向 TiKV 获取锁，`UPDATE` 立即锁定目标行，其他事务必须等待。与 MySQL InnoDB 完全一致——提交即成功，无 Write Conflict。

```
悲观事务的执行时间线：

时间线   事务A                            事务B
  T1     BEGIN;                           BEGIN;
  T2     UPDATE id=1 → 加行锁              UPDATE id=1 → ⏳ 等待锁
  T3     COMMIT;  → 释放锁
  T4                                      获取锁，继续执行
  T5                                      COMMIT;  ✅ 成功
```

悲观事务的锁机制：
- **Prewrite 阶段**：向 TiKV 写入数据并加锁
- **Commit 阶段**：写入提交记录，释放锁
- **锁粒度**：行级锁（不支持 Gap Lock）
- **死锁检测**：TiDB Leader 节点定期检测死锁并回滚
- **锁等待超时**：`innodb_lock_wait_timeout` 默认 50 秒

### 对比

| | 乐观事务（冲突率低） | 乐观事务（冲突率高） | 悲观事务 |
|---|---|---|---|
| 写入阻塞 | 无 | 无 | 有（锁等待） |
| 提交失败率 | 极低 | **高** | 极低 |
| 重试开销 | 无 | **重试爆炸** | 无 |
| 并发吞吐 | **最高** | 低 | 中等 |
| 实现复杂度 | 需重试逻辑 | 需重试+退避逻辑 | 与 MySQL 一致 |

<ExplainCompare
  :bad="{ mode: 'optimistic', conflict: '提交时检测', retry: 'Write Conflict 需重试', lock: '无锁等待' }"
  :good="{ mode: 'pessimistic', conflict: '写入时检测', retry: '无需重试', lock: '与 MySQL 一致' }"
  improvement="从提交阶段冲突检测变为写入阶段加锁，消除 Write Conflict，与 MySQL 行为完全一致"
/>

## 避坑指南

::: warning 注意事项

1. **版本差异**：TiDB 3.0 之前只支持乐观事务，3.0+ 引入悲观事务（实验），4.0 GA，6.0+ 默认悲观。升级时检查 `tidb_txn_mode`。

2. **不要混用**：同一应用尽量统一事务模型，避免连接池中存在不同 `tidb_txn_mode` 的会话。

3. **乐观事务需重试**：使用乐观模式必须在应用层实现重试逻辑（捕获 `Write conflict` 错误 + 指数退避）。

4. **长事务慎用悲观**：悲观事务持有锁时间长，可能阻塞其他事务，大事务应拆分为小事务或改用乐观模式。

5. **死锁不会丢数据**：TiDB 会自动回滚死锁事务中的较小者，应用捕获死锁错误并重试即可。

6. **历史读是利器**：`AS OF TIMESTAMP` 可实现无锁的一致性快照读，适合报表和历史数据查询。

7. **监控 Write Conflict**：通过 TiDB Dashboard 或 `INFORMATION_SCHEMA.CLUSTER_STATEMENTS_SUMMARY_HISTORY` 监控冲突率。
:::

## 乐观 vs 悲观事务选型表

| 场景 | 推荐模式 | 理由 |
|------|----------|------|
| MySQL 迁移应用 | **悲观**（默认） | 与 MySQL 行为一致，无需改代码 |
| 高冲突 OLTP（秒杀、扣减） | **悲观** | 锁等待优于重试爆炸 |
| 低冲突高并发（日志写入、事件记录） | **乐观** | 无锁等待，吞吐更高 |
| 长事务（多表关联更新） | **悲观** | 避免全部重试 |
| 读多写少（报表、分析） | **乐观** | 几乎不冲突，极致性能 |
| 微服务分布式事务 | **乐观** | 避免分布式锁，简化架构 |
| 历史数据查询 | 任一 + AS OF TIMESTAMP | TiDB 特有，无锁一致性快照 |

### 模式切换

| 方法 | 作用域 | 示例 |
|------|--------|------|
| 全局变量 | 新会话 | `SET GLOBAL tidb_txn_mode = 'pessimistic'` |
| 会话变量 | 当前会话 | `SET SESSION tidb_txn_mode = 'optimistic'` |
| 连接串参数 | JDBC | `jdbc:mysql:tidb://...?tidb_txn_mode=optimistic` |

::: tip TiDB 6.0+ 默认悲观
如果你用的是 TiDB 6.0 及以上版本，默认已是悲观事务。只需了解乐观事务的存在并在低冲突场景按需切换即可。如果从旧版 TiDB 升级，需要确认现有应用是否依赖乐观事务行为。
:::

## 本地复现

```bash
# 在 TiDB 上运行
./scripts/run-case.sh 85-tidb-transaction --ver tidb

# 跳过造数据重跑
./scripts/run-case.sh 85-tidb-transaction --ver tidb --no-seed
```
