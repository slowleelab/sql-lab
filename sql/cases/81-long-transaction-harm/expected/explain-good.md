# EXPLAIN 参考结果 - good.sql (短事务，耗时操作在事务外)

## MySQL 8.0（10 万行账户数据）

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

执行计划与 bad.sql 相同（都是主键等值操作），**优化点不在于执行计划，而在于事务边界的缩短**。

## 关键改进

| 维度 | bad.sql（长事务） | good.sql（短事务） |
|------|------------------|-------------------|
| 耗时操作位置 | 事务内（持锁期间） | 事务外（无锁） |
| 锁持有时间 | ~5000 ms | ~1 ms |
| 并发阻塞 | 严重（5 秒） | 几乎无感知 |
| undo log | 持续膨胀 | 及时 purge |
| 主从延迟 | +5 秒 | 无影响 |

## 为什么快

### 短事务时间线

```
时间线   会话A（短事务）                        会话B（不受影响）
  T1     SELECT SLEEP(5);                   -- 事务外，不持有任何锁
  T2                                          UPDATE ... WHERE id=1;
                                              -- 正常执行，无阻塞
  T3     BEGIN;
  T4     SELECT ... WHERE id=1 FOR UPDATE;  -- 加锁（毫秒级）
  T5     UPDATE ... WHERE id=1;
  T6     COMMIT;                            -- 释放锁
         => 会话B 在 T2 时刻正常执行，不受会话A 影响
```

### 优化要点

1. **耗时操作前置**：将 RPC 调用、HTTP 请求、文件 IO 等耗时操作移到事务外执行
2. **事务最小化**：事务内只做必要的加锁 + 更新，持锁时间从秒级降到毫秒级
3. **undo log 健康**：短事务让 undo log 及时 purge，避免 MVCC 快照链过长
4. **主从同步**：短事务在从库回放快，不会加剧主从延迟

### 实际项目中的应用

```java
// 错误示范：长事务
@Transactional
public void deductBalance(Long accountId, BigDecimal amount) {
    Account account = accountMapper.selectForUpdate(accountId);  // 加锁
    paymentClient.call(account);  // 调用外部支付接口（耗时 5 秒）
    accountMapper.deduct(accountId, amount);  // 更新
}

// 正确示范：短事务
public void deductBalance(Long accountId, BigDecimal amount) {
    paymentClient.call(accountId);  // 先调用外部接口（无锁）
    deductInTransaction(accountId, amount);  // 再开启短事务
}

@Transactional
public void deductInTransaction(Long accountId, BigDecimal amount) {
    Account account = accountMapper.selectForUpdate(accountId);  // 加锁
    accountMapper.deduct(accountId, amount);  // 更新
}
```

## 量化对比

| 指标 | bad.sql（长事务） | good.sql（短事务） |
|------|------------------|-------------------|
| 锁持有时间 | ~5000 ms | **~1 ms** |
| 并发事务等待 | 阻塞 5 秒 | **几乎无感知** |
| undo log 膨胀 | 严重 | **无** |
| 主从延迟 | +5 秒 | **无影响** |
| 系统吞吐量 | 急剧下降 | **稳定** |

## 5.7 vs 8.0 差异

- 短事务优化在两个版本中同样有效
- 8.0 的 `performance_schema.data_locks` 可验证锁持有时间确实缩短
- 8.0 的 undo log 管理更高效，短事务下 purge 更及时

::: tip 事务设计原则
数据库事务应遵循"最小化"原则：事务内只做必须原子执行的操作，耗时操作（外部调用、复杂计算、文件 IO）一律移到事务外。如果外部调用失败，由于尚未开启事务，无需回滚数据库，简化了异常处理逻辑。
:::
