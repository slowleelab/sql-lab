# EXPLAIN 参考结果 - good.sql（悲观事务：加锁与锁等待）

事务不产生 EXPLAIN 输出。本文说明悲观事务的加锁行为、锁等待超时机制，以及与 MySQL SELECT FOR UPDATE 的对比。

---

## 悲观事务执行流程

```
事务A (悲观)                          事务B (悲观)
  BEGIN;
  UPDATE SET balance=balance-1000
    WHERE id=1;                       BEGIN;
    -- 写入时加行锁                     UPDATE SET balance=balance-500
    -- 持有锁直到 COMMIT                   WHERE id=1;
                                      -- ⏳ 阻塞等待事务A释放锁
                                      -- （默认 innodb_lock_wait_timeout=50s）

  COMMIT;  ← 释放锁
  
                                      -- 获取锁，继续执行
                                      -- 读到 balance=9000（事务A提交后的值）
                                      -- UPDATE 为 8500
                                      COMMIT;  ← ✅ 成功
```

---

## 悲观事务加锁行为

| 阶段 | 悲观事务 | 乐观事务 |
|------|----------|----------|
| BEGIN | 获取 TSO 时间戳（start_ts） | 获取 TSO 时间戳（start_ts） |
| DML 写入 | **加锁（Acquire Lock）**，冲突则等待 | 不检查冲突，本地缓存写入 |
| SELECT | 快照读（不加锁） | 快照读（不加锁） |
| SELECT FOR UPDATE | 加悲观锁 | 不持锁（有局限性） |
| COMMIT | Prewrite + Commit（锁已持有，无冲突） | Prewrite 检测冲突 + Commit |
| 冲突处理 | 写入时等待/超时 | 提交时报错/重试 |

---

## 关键参数

```sql
-- 查看当前事务模式
SELECT @@tidb_txn_mode;
-- +--------------------+
-- | @@tidb_txn_mode    |
-- +--------------------+
-- | pessimistic        |
-- +--------------------+

-- 悲观锁等待超时
SHOW VARIABLES LIKE 'innodb_lock_wait_timeout';
-- +--------------------------+-------+
-- | Variable_name            | Value |
-- +--------------------------+-------+
-- | innodb_lock_wait_timeout | 50    |
-- +--------------------------+-------+

-- 死锁检测
SHOW VARIABLES LIKE 'tidb_deadlock_history_collect_interval';
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `tidb_txn_mode` | `pessimistic`（6.0+） | TiDB 6.0+ 默认使用悲观事务 |
| `innodb_lock_wait_timeout` | 50（秒） | 悲观锁等待超时 |
| `tidb_lock_wait_timeout` | `innodb_lock_wait_timeout` 值 | TiDB 锁等待超时（尊重 MySQL 变量） |

---

## TiDB 悲观事务 vs MySQL SELECT FOR UPDATE

| 特性 | TiDB 悲观事务 | MySQL InnoDB |
|------|--------------|--------------|
| 锁实现 | Percolator + 内存锁管理器 | 行锁 + Gap Lock |
| UPDATE 自动加锁 | 是 | 是 |
| SELECT FOR UPDATE | 加悲观锁 | 加行锁 |
| Gap Lock | 不支持 | 支持（RR 隔离级别） |
| 死锁检测 | Leader 节点检测 | InnoDB 自动检测 |
| 锁等待超时 | `innodb_lock_wait_timeout` | `innodb_lock_wait_timeout` |
| 锁信息查看 | `INFORMATION_SCHEMA.DEADLOCKS` | `performance_schema.data_locks` |

---

## AS OF TIMESTAMP 历史读（TiDB 特有）

```sql
-- 查看当前快照时间戳
SELECT @@tidb_snapshot;

-- 设置历史快照时间戳
SET @@tidb_snapshot = '2026-07-01 00:00:00';

-- 读取历史快照数据（可实现"时间旅行"查询）
SELECT * FROM t_account;

-- 恢复为当前时间
SET @@tidb_snapshot = '';
```

`AS OF TIMESTAMP` 是 TiDB 特有的功能，利用 MVCC 多版本机制实现时间旅行查询。MySQL 无此功能。

---

## 悲观事务适用场景

- **高冲突 OLTP**：多个事务频繁修改同一行
- **强一致性要求**：不允许 Write Conflict 导致的重试
- **兼容 MySQL 行为**：从 MySQL 迁移的应用无需修改事务逻辑
- **长事务**：涉及多行修改的复杂事务，避免重试代价
