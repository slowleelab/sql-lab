# EXPLAIN 参考结果 - good.sql (FOR UPDATE 间隙锁 / SERIALIZABLE 防幻读)

## MySQL 8.0（RR 下 FOR UPDATE，或 SERIALIZABLE）

```
-- EXPLAIN SELECT * FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_transaction_log | NULL       | range | idx_amount    | idx_amount | 6       | NULL | 49803  |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
```

```
-- 查看 FOR UPDATE 加的锁（8.0 performance_schema.data_locks）
SELECT index_name, lock_type, lock_mode, lock_data
FROM performance_schema.data_locks
WHERE object_name = 't_transaction_log';
+------------+-----------+-----------+-----------+
| index_name | lock_type | lock_mode | lock_data |
+------------+-----------+-----------+-----------+
| NULL       | TABLE     | IX        | NULL      |
| idx_amount | RECORD    | X         | 4999.99   |  -- next-key: (间隙,4999.99]
| idx_amount | RECORD    | X,GAP     | 6001.00   |  -- 间隙锁 (4999.99, 6001.00)
+------------+-----------+-----------+-----------+
-- 间隙 (5000, 6000) 被 X,GAP 锁定，阻止插入
```

## 关键改进

| 维度 | bad.sql（普通读） | good.sql（FOR UPDATE / SERIALIZABLE） |
|------|------------------|--------------------------------------|
| 读类型 | 快照读（无锁） | 当前读（加间隙锁） |
| lock_mode | 无锁 | `X` + `X,GAP` |
| 间隙锁 | 无 | **有**（锁定 5000~6000 间隙） |
| 插入 amount=5500 | 成功（产生幻读） | **被阻塞**（无幻读） |

## 为什么能防幻读

### 间隙锁阻止插入

- `WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE` 在 RR 下加 next-key lock
- 锁定范围包括间隙 (4999.99, 6001.00)，即 5000~6000 之间的空隙
- 其他事务 INSERT amount=5500 落在间隙内，被间隙锁阻塞

```
时间线   会话A（RR + FOR UPDATE）          会话B
  T1     BEGIN;
  T2     SELECT ... WHERE tx_amount         -- 加间隙锁 (5000,6000)
            BETWEEN 5000 AND 6000 FOR UPDATE;
  T3                                       BEGIN;
  T4                                       INSERT ... VALUES (5500);
                                           -- ❌ 被间隙锁阻塞！
  T5     SELECT COUNT(*) ... BETWEEN       -- 范围内仍为 0
            5000 AND 6000;  -> 0           -- 无幻读（会话B无法插入）
  T6     COMMIT;   -- 释放间隙锁
  T7                                       获取锁，INSERT 完成
```

### SERIALIZABLE 隔离级别

- 配合 setup-good.sql 执行 `SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE`
- SERIALIZABLE 下，**普通 SELECT 也会自动加共享锁 + 间隙锁**
- 无需显式 FOR UPDATE 即可防幻读，但并发性能下降明显

### 防幻读方案对比

| 方案 | 机制 | 并发影响 | 适用场景 |
|------|------|---------|---------|
| SELECT FOR UPDATE | 显式加间隙锁 | 中（锁间隙） | RR 下精确控制 |
| SERIALIZABLE | 自动加锁 | 高（所有读加锁） | 强一致性要求 |
| RC + 业务层 | 不防幻读，业务兜底 | 低 | 高并发、容忍幻读 |
| 唯一索引约束 | 防重复插入 | 低 | 仅防重复 |

## 量化对比

| 指标 | bad.sql | good.sql |
|------|---------|----------|
| 幻读 | 有 | **无** |
| 范围内插入 | 允许 | **阻塞** |
| 读一致性 | 快照读一致，当前读不一致 | **完全一致** |
| 并发插入吞吐 | 高 | 降低（间隙锁阻塞） |

## 避坑指南

1. **区分快照读与当前读**：RR 下普通 SELECT 是快照读不会幻读，但 FOR UPDATE/UPDATE 是当前读会幻读
2. **仅需防幻读时用 FOR UPDATE**：不要无脑用 SERIALIZABLE，会大幅降低并发
3. **范围查询走索引**：FOR UPDATE 的范围条件必须走索引，否则锁全表（见案例28）
4. **高并发优先 RC**：RC 无间隙锁不防幻读，但并发高、死锁少，幻读由业务唯一约束兜底
5. **间隙锁有代价**：防幻读的代价是阻塞间隙内的插入，权衡一致性与并发性
6. **MVCC 已解决大部分问题**：RR 的快照读已保证事务内一致，只有当前读才需关注幻读

## 5.7 vs 8.0 差异

- 间隙锁防幻读机制一致
- 8.0 可通过 `data_locks` 精确查看间隙锁范围（lock_mode 含 GAP）
- SERIALIZABLE 的行为在两个版本一致，均为所有读自动加锁
