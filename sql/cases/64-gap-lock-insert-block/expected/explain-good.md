# EXPLAIN 参考结果 - good.sql (RC 隔离级别 / 精确等值，无间隙锁)

## MySQL 8.0（配合 setup-good.sql 切到 RC，或使用精确等值查询）

```
-- 方案一：RC 下范围查询 FOR UPDATE
-- SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- EXPLAIN SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref  | rows | filtered | Extra |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
|  1 | SIMPLE      | t_account | NULL       | range | PRIMARY       | PRIMARY | 8       | NULL |    2 |   100.00 | NULL  |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
```

```
-- 方案二：精确等值查询 FOR UPDATE
-- EXPLAIN SELECT * FROM t_account WHERE id = 10 FOR UPDATE;
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_account | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+-----------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
```

```
-- RC 下 FOR UPDATE 的锁（8.0 performance_schema.data_locks）
SELECT object_name, index_name, lock_type, lock_mode, lock_data
FROM performance_schema.data_locks
WHERE object_name = 't_account';
+-------------+------------+-----------+-----------+-----------+
| object_name | index_name | lock_type | lock_mode | lock_data |
+-------------+------------+-----------+-----------+-----------+
| t_account   | NULL       | TABLE     | IX        | NULL      |
| t_account   | PRIMARY    | RECORD    | X,REC_NOT_GAP | 10    |  -- 仅记录锁
| t_account   | PRIMARY    | RECORD    | X,REC_NOT_GAP | 20    |  -- 仅记录锁
+-------------+------------+-----------+-----------+-----------+
-- 注意：RC 下没有 X,GAP 间隙锁！
```

## 关键改进

| 维度 | bad.sql（RR 范围） | good.sql（RC / 精确等值） |
|------|-------------------|-------------------------|
| lock_mode | `X` + `X,GAP`（含间隙锁） | `X,REC_NOT_GAP`（仅记录锁） |
| 插入 id=15 | 阻塞 | **不阻塞** |
| 锁范围 | 区间 + 间隙 | 仅命中行 |
| 幻读防护 | 有（间隙锁） | 无（业务层保证） |

## 为什么不阻塞插入

### 方案一：RC 隔离级别

- **RC（READ COMMITTED）**不加间隙锁，FOR UPDATE 只对实际命中的行加记录锁
- id=10、id=20 各加一个记录锁，间隙 (10,20) **不加锁**
- 事务B 插入 id=15 不在任何记录锁上，直接成功

```
时间线   会话A（RC 范围加锁）               会话B（插入成功）
  T1     SET SESSION TRANSACTION ISOLATION
            LEVEL READ COMMITTED;
  T2     BEGIN;
  T3     SELECT ... WHERE id BETWEEN 10
            AND 20 FOR UPDATE;   -- 仅锁 id=10、id=20 记录
  T4                                        BEGIN;
  T5                                        INSERT ... VALUES (15,...);
                                            -- ✅ 插入成功！无间隙锁
```

### 方案二：精确等值查询

- `WHERE id = 10 FOR UPDATE`（唯一索引等值命中）只加记录锁
- RR 下唯一索引等值命中记录时，也是记录锁而非 next-key lock
- 不触碰间隙，不影响插入

### RC vs RR 的权衡

| 维度 | RR（默认） | RC |
|------|-----------|-----|
| 幻读 | 防止（间隙锁） | 允许 |
| 锁范围 | 大（含间隙） | 小（仅记录） |
| 并发插入 | 易阻塞 | 不阻塞 |
| 死锁概率 | 较高 | 较低 |
| 适用场景 | 强一致性 | 高并发、业务可容忍幻读 |

## 量化对比

| 指标 | bad.sql（RR） | good.sql（RC） |
|------|--------------|----------------|
| 间隙锁 | 有 | **无** |
| 插入阻塞 | 是 | **否** |
| 并发吞吐 | 低（插入排队） | **高** |
| 死锁风险 | 高 | 低 |

## 避坑指南

1. **高并发场景优先 RC**：RC 不加间隙锁，插入不阻塞，死锁概率低；幻读由业务唯一索引或版本号兜底
2. **RR 下避免范围 FOR UPDATE**：范围条件会加大量间隙锁，尽量用精确等值替代
3. **缩短持锁事务**：FOR UPDATE 后尽快 COMMIT，减少锁持有时间
4. **按主键精确加锁**：`WHERE id = N FOR UPDATE`（唯一索引等值命中）只加记录锁
5. **8.0 可查锁详情**：`performance_schema.data_locks` 精确查看 lock_mode 判断是否有 GAP

## 5.7 vs 8.0 差异

- RC 消除间隙锁的行为在 5.7 和 8.0 一致
- 8.0 的 `data_locks` 表让锁分析更直观；5.7 需读 `SHOW ENGINE INNODB STATUS` 的 RECORD LOCKS 段
