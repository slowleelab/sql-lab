# EXPLAIN 参考结果 - bad.sql (普通快照读，当前读幻读)

## MySQL 8.0（RR 隔离级别，10 万行，amount 5000~6000 间隙为空）

```
-- EXPLAIN SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+
| id | select_type | table             | partitions | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra                    |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+
|  1 | SIMPLE      | t_transaction_log | NULL       | range | idx_amount    | idx_amount | 6       | NULL | 49803  |   100.00 | Using where; Using index |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+
```

```
-- EXPLAIN SELECT COUNT(*) ... FOR UPDATE;（当前读）
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_transaction_log | NULL       | range | idx_amount    | idx_amount | 6       | NULL | 49803  |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 走 idx_amount 索引范围扫描 |
| key | `idx_amount` | 使用了金额索引 |
| rows | ~49,803 | 范围内扫描行数（含间隙边界附近） |
| Extra（普通读） | `Using index` | 覆盖索引，不回表 |
| Extra（FOR UPDATE） | `Using where` | 当前读，需加锁 |

查询本身走了索引，**问题不在性能，而在幻读正确性**。

## 为什么会幻读

### RR 下的快照读与当前读

- **快照读（普通 SELECT）**：基于 MVCC 读取事务开始时的快照，同一事务内一致
- **当前读（FOR UPDATE / UPDATE / DELETE）**：读取最新已提交数据，能看到其他事务的新插入

### 幻读复现时间线

```
时间线   会话A（RR）                       会话B
  T1     BEGIN;
  T2     SELECT COUNT(*) ... BETWEEN       -- 快照读，结果 0
            5000 AND 6000;  -> 0
  T3                                       BEGIN;
  T4                                       INSERT ... VALUES (5500);
  T5                                       COMMIT;  -- 新行已提交
  T6     SELECT COUNT(*) ... BETWEEN       -- 快照读，仍是 0（快照未变）
            5000 AND 6000;  -> 0
  T7     SELECT COUNT(*) ... FOR UPDATE;   -- 当前读，看到幻影行
         -> 1  ❌ 幻读！
  T8     UPDATE ... SET tx_amount=tx_amount
         WHERE tx_amount BETWEEN 5000 AND 6000;
         -> Rows matched: 1  （当前读也看到幻影行）
  T9     COMMIT;
```

### 快照读 vs 当前读对比

| 读类型 | 语句 | T2 结果 | T6 结果 | T7 结果 |
|--------|------|---------|---------|---------|
| 快照读 | SELECT | 0 | 0（一致） | - |
| 当前读 | SELECT FOR UPDATE | - | - | **1（幻读）** |
| 当前读 | UPDATE 触发 | - | - | matched: 1 |

- 快照读在 T2、T6 一致（MVCC 保证），看起来"没有幻读"
- 但当前读（T7）看到幻影行，业务逻辑基于快照读判断、基于当前读操作时产生不一致

### 幻读的危害

```python
# 基于快照读的业务逻辑：
count = db.query("SELECT COUNT(*) FROM t_log WHERE amount BETWEEN 5000 AND 6000")
if count == 0:
    # 认为范围内无数据，执行某些操作
    # 但此时其他事务已插入 amount=5500
    db.execute("UPDATE t_log SET status='checked' WHERE amount BETWEEN 5000 AND 6000")
    # 结果：UPDATE 命中了幻影行（当前读），与 count==0 的判断矛盾
```

## 5.7 vs 8.0 差异

- RR 快照读/当前读机制一致，幻读现象相同
- 8.0 可用 `data_locks` 查看快照读无锁、当前读加锁的差异
