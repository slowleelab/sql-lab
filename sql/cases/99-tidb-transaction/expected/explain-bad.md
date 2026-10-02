# EXPLAIN 参考结果 - bad.sql（乐观事务：Write Conflict 机制）

事务不产生 EXPLAIN 输出。本文说明乐观事务的 Write Conflict 机制、冲突检测流程和重试限制。

---

## 乐观事务执行流程

```
事务A (乐观)                          事务B (乐观)
  BEGIN;
  UPDATE SET balance=balance-1000
    WHERE id=1;                       BEGIN;
    -- 此时不持锁                      UPDATE SET balance=balance-500
    -- 本地写入缓存，未提交                WHERE id=1;
                                      -- 同样不持锁，本地缓存写入
                                      COMMIT;  ← 先提交成功

  COMMIT;  ← ❌ Write Conflict!
  -- TiDB 检测到 id=1 的版本已被事务B修改
  -- 提交被拒绝，需要客户端重试整个事务
```

---

## Write Conflict 检测机制

| 阶段 | 乐观事务 | 悲观事务 |
|------|----------|----------|
| 写入时 | 不检查冲突，更新本地缓存 | 加锁，冲突则等待或超时 |
| 提交时 | 检查所有写入行的版本，冲突则失败 | 直接提交（因为锁已保证无冲突） |
| 冲突检测时机 | **提交阶段（Prewrite）** | **写入阶段（Acquire Lock）** |

乐观事务在 Prewrite 阶段通过 TiKV 的 Percolator 模型检测冲突：对比每一行的 `start_ts` 版本号与当前最新版本，若发现该行已被其他事务修改则触发 Write Conflict。

---

## Write Conflict 常见场景

| 问题 | 说明 |
|------|------|
| 冲突行 | 两个事务修改了同一行（如 t_account.id=1） |
| 冲突检测 | TiDB 在 Prewrite 阶段发现版本冲突 |
| 报错信息 | `ERROR 8028 (HY000): Information schema is changed during the execution of the statement` 或 `Write conflict` |
| 解决方案 | 客户端捕获错误并重试 |
| 重试参数 | `tidb_retry_limit`（默认 10），`tidb_disable_txn_auto_retry` |

---

## 乐观事务重试限制

```sql
SHOW VARIABLES LIKE 'tidb_retry_limit';
-- +-------------------+-------+
-- | Variable_name     | Value |
-- +-------------------+-------+
-- | tidb_retry_limit  | 10    |
-- +-------------------+-------+

SELECT @@tidb_txn_mode;
-- +--------------------+
-- | @@tidb_txn_mode    |
-- +--------------------+
-- | optimistic         |
-- +--------------------+
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `tidb_txn_mode` | `pessimistic`（6.0+） | 事务模型：optimistic / pessimistic |
| `tidb_retry_limit` | 10 | 乐观事务冲突后最大重试次数 |
| `tidb_disable_txn_auto_retry` | ON（6.0+） | 是否禁用自动重试 |

注意：TiDB 6.0 起默认禁用乐观事务的自动重试（`tidb_disable_txn_auto_retry = ON`），建议应用层自行捕获并重试。

---

## 乐观事务适用场景

- **读多写少**：大部分事务只读，写入冲突概率低
- **低冲突 OLTP**：不同事务操作不同行，几乎没有行级冲突
- **高并发写入**：重试开销远小于悲观锁的锁等待开销
- **短事务**：事务执行时间短，冲突窗口窄
