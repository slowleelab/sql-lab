# EXPLAIN 参考结果 - bad.sql（普通 FOR UPDATE）

## TiDB 悲观模式（5 行测试数据）

---

### 会话A: 加锁后查看锁信息

```sql
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
```

```
+----+-----------+------+
| id | item_name | qty  |
+----+-----------+------+
|  1 | alice     |  100 |
+----+-----------+------+
```

行为：查询成功返回，事务持有 id=1 的行锁（X 锁），锁持续到 COMMIT/ROLLBACK。

---

### 会话B: 尝试获取同一行的锁（阻塞）

```sql
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
```

阻塞等待，直到会话A提交释放锁，或达到 `innodb_lock_wait_timeout`（默认 50s）超时。

超时报错：
```
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

---

### 锁等待期间：DATA_LOCK_WAITS 视图

```sql
SELECT * FROM information_schema.data_lock_waits;
```

```
+-------------------+------------------+-------------------+--------------+---------------------+
| REQUESTING_TRX_ID | BLOCKING_TRX_ID  | WAIT_KEY          | WAIT_START_TIME     | ...              |
+-------------------+------------------+-------------------+--------------+---------------------+
|         4536789012 |       4536789011 | 7480000000000000FF| 2026-07-28 10:00:01 | ...              |
+-------------------+------------------+-------------------+--------------+---------------------+
```

| 字段 | 含义 |
|------|------|
| `REQUESTING_TRX_ID` | 等待锁的事务 ID（会话B） |
| `BLOCKING_TRX_ID` | 持有锁的事务 ID（会话A） |
| `WAIT_KEY` | 被锁定的 Key（含表ID和行ID） |
| `WAIT_START_TIME` | 锁等待开始时间 |

---

### CLUSTER_PROCESSLIST 输出（锁等待时）

```sql
SELECT id, user, db, command, time, state, info
FROM information_schema.cluster_processlist
WHERE command != 'Sleep';
```

```
+------+------+--------+---------+------+---------------------------------------+----------------------------------------------+
| id   | user | db     | command | time | state                                 | info                                         |
+------+------+--------+---------+------+---------------------------------------+----------------------------------------------+
| 1001 | root | test   | Query   |    0 | autocommit                            | SELECT * FROM information_schema...          |
| 1002 | root | test   | Query   |   12 | Waiting for pessimistic lock          | SELECT * FROM t_lock_test WHERE id=1 FOR ... |
+------+------+--------+---------+------+---------------------------------------+----------------------------------------------+
```

- 会话 1002 的 `state = 'Waiting for pessimistic lock'` 指示该连接正在等待锁
- `time = 12` 表示已等待 12 秒

---

## 问题分析

### 普通 FOR UPDATE 的阻塞链示意

```
时间线     会话A                      会话B                      会话C
  T1       BEGIN;
  T2       SELECT ... FOR UPDATE;    -- 持有 id=1 锁
  T3                                 BEGIN;
  T4                                 SELECT ... FOR UPDATE;     -- 阻塞等待
  T5                                                             BEGIN;
  T6                                                             SELECT ... FOR UPDATE; -- 阻塞等待
  T7       COMMIT;                   -- 释放锁
  T8                                 获取锁，执行 COMMIT;
  T9                                                             获取锁，执行 COMMIT;
```

- T2-T7 期间，会话A 持有行锁，会话B、C 被阻塞
- 连接池中的连接被占满等待，新建请求无法获取连接
- 如果会话A 长时间未提交（应用逻辑耗时），等待方最终超时报错

### 连接池耗尽场景

假设连接池大小为 10：

```
请求1    请求2    请求3    请求4    ...    请求10    请求11
  │        │        │        │               │         │
  ▼        ▼        ▼        ▼               ▼         ▼
获取id=1  等待id=1  等待id=1  等待id=1     等待id=1   无可用连接
持有锁    (阻塞)   (阻塞)   (阻塞)        (阻塞)    ❌ 失败
```

所有连接要么持有锁、要么等待锁，连接池被"锁死"。

### MySQL vs TiDB 锁对比

| 维度 | MySQL InnoDB | TiDB (悲观模式) |
|------|-------------|----------------|
| 行锁实现 | 基于索引的 Record Lock / Gap Lock | 基于 Key（TIDB_ROW_KEY）的分布式锁 |
| 锁信息查看 | `performance_schema.data_locks` | `information_schema.data_lock_waits` |
| 锁等待查看 | `performance_schema.data_lock_waits` | `information_schema.data_lock_waits` |
| 进程列表 | `SHOW PROCESSLIST` | `information_schema.cluster_processlist` |
| 锁超时 | `innodb_lock_wait_timeout`（默认 50s） | `innodb_lock_wait_timeout`（默认 50s，兼容） |
| 死锁检测 | InnoDB 自动检测，回滚代价小的事务 | TiDB 自动检测，回滚一个事务 |
| FOR UPDATE NOWAIT | 8.0+ 支持 | 支持（与 MySQL 8.0 兼容） |
| FOR UPDATE SKIP LOCKED | 8.0+ 支持 | 支持（与 MySQL 8.0 兼容） |
