# EXPLAIN 参考结果 - bad.sql (长事务持锁，默认超时 50 秒)

## MySQL 8.0（5 万行计数器数据）

```
-- EXPLAIN UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table                | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_concurrent_counter | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

```
-- 查看当前锁等待超时设置（默认 50 秒）
SELECT @@innodb_lock_wait_timeout;
+----------------------------+
| @@innodb_lock_wait_timeout |
+----------------------------+
|                         50 |
+----------------------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 主键等值更新，单行高效 |
| key | `PRIMARY` | 走主键索引 |
| rows | 1 | 精确命中 1 行 |
| timeout | 50 秒 | **默认超时过长** |

UPDATE 本身极快，**问题在于长事务持锁导致其他事务等待 50 秒超时**。

## 为什么会超时

### 长事务持锁时间线

```
时间线   会话A（长事务）                  会话B（等待超时）
  T0     BEGIN;
  T1     UPDATE id=1;  -- 持有行锁
  T2     -- 执行慢操作（远程调用/大查询）
         -- 行锁持续持有...
  T3                                      BEGIN;
  T4                                      UPDATE id=1;  -- 等待行锁
  T5     -- 仍在慢操作中...                 -- 等待中...（已等 5s）
  ...
  T50                                     -- 等待满 50 秒
                                          ERROR 1205 (HY000): Lock wait timeout
                                          exceeded; try restarting transaction
  T51     -- 慢操作结束，COMMIT
```

### 超时错误的类型与处理

| 错误码 | 含义 | 触发条件 | 处理方式 |
|--------|------|---------|---------|
| 1205 | Lock wait timeout | 行锁等待超时（innodb_lock_wait_timeout） | 重试事务 |
| 1213 | Deadlock | 死锁被回滚 | 重试事务 |
| 1206 | Lock table full | 锁内存不足 | 检查 innodb_buffer_pool |

### 默认超时 50 秒的危害

- **连接资源占用**：等待 50 秒期间连接池连接被占用，可能耗尽
- **请求堆积**：后续请求排队，雪崩风险
- **用户体验差**：用户等待 50 秒才报错
- **无重试机制**：超时后直接报错，无自动恢复

### 查看锁等待状态（8.0）

```sql
-- 查看当前锁等待
SELECT
    r.trx_id AS waiting_trx_id,
    r.trx_state AS waiting_state,
    r.trx_wait_started AS wait_started,
    TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS wait_seconds,
    b.trx_id AS blocking_trx_id,
    b.trx_state AS blocking_state
FROM information_schema.innodb_trx r
JOIN information_schema.innodb_trx b
  ON b.trx_id = (SELECT blocking_trx_id FROM performance_schema.data_lock_waits
                 WHERE requesting_trx_id = r.trx_id LIMIT 1);
```

## 5.7 vs 8.0 差异

- innodb_lock_wait_timeout 默认值均为 50 秒
- 8.0 可通过 `performance_schema.data_lock_waits` 精确查看等待关系
- 超时报错信息一致：ERROR 1205
