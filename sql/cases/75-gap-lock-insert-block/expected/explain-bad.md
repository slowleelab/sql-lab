# EXPLAIN 参考结果 - bad.sql (RR 范围 FOR UPDATE 加间隙锁)

## MySQL 8.0（RR 隔离级别，id 1~10 + id=20，间隙 11~19）

```
-- EXPLAIN SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref  | rows | filtered | Extra |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
|  1 | SIMPLE      | t_account | NULL       | range | PRIMARY       | PRIMARY | 8       | NULL |    2 |   100.00 | NULL  |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
```

```
-- 查看 FOR UPDATE 实际加的锁（8.0 performance_schema.data_locks）
-- 在会话A执行 BEGIN; SELECT ... FOR UPDATE; 后查询：
SELECT object_name, index_name, lock_type, lock_mode, lock_data, lock_status
FROM performance_schema.data_locks
WHERE object_name = 't_account';
+-------------+------------+-----------+-----------+-----------+-------------+
| object_name | index_name | lock_type | lock_mode | lock_data | lock_status |
+-------------+------------+-----------+-----------+-----------+-------------+
| t_account   | NULL       | TABLE     | IX        | NULL      | GRANTED     |
| t_account   | PRIMARY    | RECORD    | X,REC_NOT_GAP | 10    | GRANTED     |  -- id=10 记录锁
| t_account   | PRIMARY    | RECORD    | X          | 20       | GRANTED     |  -- id=20 next-key锁(含间隙)
| t_account   | PRIMARY    | RECORD    | X,GAP      | 20       | GRANTED     |  -- (10,20) 间隙锁
+-------------+------------+-----------+-----------+-----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 主键范围扫描 |
| key | `PRIMARY` | 走主键索引 |
| rows | 2 | 实际命中 id=10、id=20 两行 |
| lock_mode | `X` + `X,GAP` | **加锁范围远大于命中行数** |

## 为什么会阻塞插入

### RR 隔离级别的间隙锁机制

- **RR（REPEATABLE READ）**是 MySQL 默认隔离级别，为防止幻读，范围查询会加 **next-key lock**（记录锁 + 间隙锁）
- `WHERE id BETWEEN 10 AND 20 FOR UPDATE` 加锁范围：
  - id=10：记录锁（`X,REC_NOT_GAP`）
  - (10, 20)：间隙锁（`X,GAP`）— 锁定 10 和 20 之间的所有空隙
  - id=20：next-key 锁（`X`）— 记录锁 + 后方间隙锁

### 插入阻塞复现

```
时间线   会话A（RR，范围加锁）              会话B（插入被阻塞）
  T1     BEGIN;
  T2     SELECT ... WHERE id BETWEEN 10
            AND 20 FOR UPDATE;   -- 加间隙锁 (10,20)
  T3                                        BEGIN;
  T4                                        INSERT INTO t_account (id,...) VALUES (15,...);
                                            -- id=15 落在间隙 (10,20) 内
                                            -- ❌ 被阻塞！等待间隙锁释放
  T5     （未提交，仍持锁）
         ...
  T6                                        超时：ERROR 1205 (HY000):
                                           Lock wait timeout exceeded
```

### 间隙锁的影响范围

| 操作 | 是否被阻塞 | 原因 |
|------|-----------|------|
| INSERT id=15 | **是** | 15 在间隙 (10,20) 内 |
| INSERT id=12 | **是** | 12 在间隙 (10,20) 内 |
| UPDATE id=10 | **是** | 10 的记录锁被持有 |
| UPDATE id=5 | 否 | 5 不在锁范围内 |
| INSERT id=25 | 否 | 25 超过 20，不在该间隙 |

## 5.7 vs 8.0 差异

- RR 间隙锁机制在 5.7 和 8.0 中行为一致
- 8.0 可通过 `performance_schema.data_locks` 直观查看锁类型；5.7 只能从 `SHOW ENGINE INNODB STATUS` 间接分析
