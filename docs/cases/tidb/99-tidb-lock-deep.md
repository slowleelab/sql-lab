# TiDB 锁机制深度解析

<CaseMeta difficulty="⭐⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['锁', 'FOR UPDATE', 'NOWAIT', 'SKIP LOCKED', 'LOCK VIEW', '悲观锁']" />

## 某电商平台在大促秒杀期间,耗尽
某电商平台在大促秒杀期间，系统突然大面积卡死——用户页面长时间无响应，监控显示数据库连接池耗尽（Active Connections 打满），大量请求堆在队列中等待。DBA 登录数据库排查：

```sql
-- 发现大量连接处于 "Waiting for pessimistic lock" 状态
SELECT command, state, COUNT(*) AS cnt, MAX(time) AS max_wait_sec
FROM information_schema.cluster_processlist
WHERE command != 'Sleep'
GROUP BY command, state
ORDER BY cnt DESC;
```

```
+--------+---------------------------------+------+--------------+
| command| state                           | cnt  | max_wait_sec |
+--------+---------------------------------+------+--------------+
| Query  | Waiting for pessimistic lock    |   48 |          210 |
| Query  | executing                       |    2 |            3 |
+--------+---------------------------------+------+--------------+
```

**48 个连接全部在等待锁**，等待时间最长的已超过 3 分钟。定位到问题 SQL：

```sql
-- 秒杀扣减逻辑中使用的悲观锁
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- 应用层判断库存 > 0，执行扣减
UPDATE t_lock_test SET qty = qty - 1 WHERE id = 1 AND qty > 0;
COMMIT;
```

问题根源：**所有并发请求争抢同一行（id=1）的行锁**。`FOR UPDATE` 的阻塞等待机制让请求排队，每个请求持有锁期间（网络往返 + 应用逻辑处理），后续请求全部等待。连接池被占满后，新的请求无法获取数据库连接，系统陷入雪崩。

::: warning 真实场景
这不是一个理论上的"可能发生"的问题。任何使用 `SELECT FOR UPDATE` 做库存扣减、余额变更、状态流转的系统，在高并发场景下都会遇到这个瓶颈。**如果你的应用代码里出现了 `FOR UPDATE`，要立刻问自己三个问题：并发量多大？持锁时间多长？是否需要 NOWAIT / SKIP LOCKED？**
:::

## 核心认知：TiDB 悲观锁与 MySQL 的差异

TiDB 的悲观锁实现与 MySQL InnoDB 的原理相似（SELECT FOR UPDATE 在事务期间持有行锁），但由于 TiDB 是分布式数据库，锁的存储和可见性机制有本质差异。

### MySQL InnoDB 行锁

```
MySQL InnoDB:
  SELECT FOR UPDATE
    → 在聚簇索引记录上加 X Lock（Rec Not Gap）
    → 锁存储在 Buffer Pool 的 lock rec 结构中
    → 通过 performance_schema.data_locks 查看
    → 锁信息在内存中，节点本地可见
```

### TiDB 悲观锁

```
TiDB (悲观模式):
  SELECT FOR UPDATE
    → TiDB server 向 TiKV 发送 PessimisticLock 请求
    → 锁存储在 TiKV 的 lock column family 中（分布式锁）
    → 通过 information_schema.data_lock_waits 查看
    → 锁信息分散在多个 TiKV 节点，需聚合查询
```

### 关键差异对照

| 维度 | MySQL InnoDB | TiDB (悲观模式) |
|------|-------------|----------------|
| 锁存储位置 | Buffer Pool (内存) | TiKV RocksDB (持久化) |
| 锁信息查询 | `performance_schema.data_locks` | `information_schema.data_lock_waits` |
| 锁粒度 | Record Lock / Gap Lock / Next-Key Lock | 基于 Key 的分布式锁 |
| 死锁检测 | InnoDB 自动回滚代价小的事务 | TiDB 自动检测并回滚一个事务 |
| 锁超时 | `innodb_lock_wait_timeout`（默认 50s） | `innodb_lock_wait_timeout`（TiDB 7.x 默认 3s；v6.x 及以下默认 50s） |
| FOR UPDATE NOWAIT | MySQL 8.0+ | 支持（兼容 MySQL 8.0） |
| FOR UPDATE SKIP LOCKED | MySQL 8.0+ | 支持（兼容 MySQL 8.0） |
| 分布式锁可见性 | 单节点，所有锁在同一实例 | 多 TiKV 节点，需聚合查询 |
| 进程列表 | `SHOW PROCESSLIST` | `CLUSTER_PROCESSLIST`（跨节点聚合） |

### 三种 FOR UPDATE 变体的语义

```
SQL 语义                         锁不可用时的行为
───────────────────────────────────────────────────
SELECT ... FOR UPDATE           阻塞等待，直到超时（50s）
SELECT ... FOR UPDATE NOWAIT    立即返回 ERROR 3572，不等待
SELECT ... FOR UPDATE SKIP LOCKED 跳过被锁定的行，返回未锁定的行
```

```
时间线示意（三个并发请求争抢同一行 id=1）:

FOR UPDATE（阻塞等待）:
  请求A: [获取锁]══════════════════[释放锁]
  请求B:         [等待.............获取锁]══════[释放锁]
  请求C:                [等待..................获取锁]══[释放锁]
  问题: B和C的空闲等待占满连接池

FOR UPDATE NOWAIT（立即失败）:
  请求A: [获取锁]══════════════════[释放锁]
  请求B:         [ERROR 3572] → 应用层处理（重试/降级）
  请求C:                [ERROR 3572] → 应用层处理
  效果: B和C立即释放连接，不给数据库压力

FOR UPDATE SKIP LOCKED（跳过）:
  请求A: [锁 id=1]══════════════[释放锁]
  请求B: [跳过id=1, 锁 id=2]════[释放锁]
  请求C: [跳过id=1,2, 锁 id=3]══[释放锁]
  效果: 三个请求处理三个不同的行，完全并行
```

---

## 问题分析

### bad.sql：普通 FOR UPDATE 的阻塞链

```sql
-- 会话A: 持有 id=1 的行锁
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;

-- 会话B: 尝试获取同一行的锁，阻塞等待
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- ❌ 阻塞等待，状态: Waiting for pessimistic lock
```

### 阻塞链路排查

```sql
-- 1. 查看锁等待关系
SELECT * FROM information_schema.data_lock_waits;
```

```
+-------------------+------------------+-------------------+---------------------+
| REQUESTING_TRX_ID | BLOCKING_TRX_ID  | WAIT_KEY          | WAIT_START_TIME     |
+-------------------+------------------+-------------------+---------------------+
|         4536789012 |       4536789011 | 7480000000000000FF| 2026-07-28 10:00:01 |
+-------------------+------------------+-------------------+---------------------+
```

- `REQUESTING_TRX_ID = 4536789012`（会话B）正在等待 `BLOCKING_TRX_ID = 4536789011`（会话A）释放锁
- `WAIT_KEY` 包含被锁定的表 ID 和行 ID

```sql
-- 2. 找到阻塞源（持有锁的连接）
SELECT id, user, host, db, command, time, state, info
FROM information_schema.cluster_processlist
WHERE command != 'Sleep'
  AND time > 10;
```

```
+------+------+-----------+------+---------+------+---------------------------------+--------------------------+
| id   | user | host      | db   | command | time | state                           | info                     |
+------+------+-----------+------+---------+------+---------------------------------+--------------------------+
| 1001 | root | 10.0.0.1 | test | Query   |  125 | executing (transaction)         | NULL                     |
| 1002 | root | 10.0.0.2 | test | Query   |   30 | Waiting for pessimistic lock    | SELECT * FROM t_lock_... |
+------+------+-----------+------+---------+------+---------------------------------+--------------------------+
```

- 连接 1001（会话A）：`state = 'executing (transaction)'`，事务已开启但无正在执行的 SQL，持有锁未释放
- 连接 1002（会话B）：`state = 'Waiting for pessimistic lock'`，等待了 30 秒

```sql
-- 3. 解决方案：终止阻塞源或等待方
-- 终止等待方（释放连接池资源）：
KILL TIDB 1002;

-- 或者终止阻塞源（需要业务确认安全）：
KILL TIDB 1001;
```

### 连接池耗尽机制

```
连接池（size=10）的状态演变:

时刻 T0（正常）:     [空闲] [空闲] [空闲] [空闲] [空闲] [空闲] [空闲] [空闲] [空闲] [空闲]
                     连接1   连接2   连接3   连接4   连接5   连接6   连接7   连接8   连接9  连接10

时刻 T1（5个请求）:  [请求A] [请求B] [请求C] [请求D] [请求E] [空闲] [空闲] [空闲] [空闲] [空闲]
                     持有锁   等待     等待     等待     等待

时刻 T2（10个请求）: [请求A] [请求B] [请求C] [请求D] [请求E] [请求F] [请求G] [请求H] [请求I] [请求J]
                     持有锁   等待     等待     等待     等待     等待     等待     等待     等待     等待

时刻 T3（第11个请求）: ❌ 连接池耗尽，请求11无法获取数据库连接
                     应用层报错: "Cannot get connection from pool (timeout)"
```

核心问题：**连接被"无效等待"占用**——连接 B-J 实际上没有在做任何有用的工作，只是在枯等连接 A 释放锁。如果使用 `NOWAIT` 或 `SKIP LOCKED`，这些连接可以立即释放，供其他请求使用。

---

## 优化方案

### good.sql：NOWAIT 和 SKIP LOCKED 实战

#### 方案一：FOR UPDATE NOWAIT（快速失败模式）

```sql
-- 如果获取不到锁就立即报错，应用层决定重试还是降级
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE NOWAIT;
-- 如果报错 ERROR 3572，应用层选择：
--   1. 短暂 sleep 后重试（适合轻量操作）
--   2. 返回给用户"系统繁忙，请稍后再试"（秒杀场景）
--   3. 降级为无锁方案（读库存缓存 + 异步扣减队列）
```

```python
# 应用层 NOWAIT 重试模式
import time

for attempt in range(max_retry := 3):
    try:
        cursor.execute("""
            SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE NOWAIT
        """)
        row = cursor.fetchone()
        if row['qty'] > 0:
            cursor.execute("UPDATE t_lock_test SET qty = qty - 1 WHERE id = 1 AND qty > 0")
            connection.commit()
            return "扣减成功"
    except Exception as e:
        if e.errno == 3572:  # NOWAIT lock conflict
            time.sleep(0.01 * (attempt + 1))  # 指数退避
            continue
        raise

return "系统繁忙，请稍后再试"
```

#### 方案二：FOR UPDATE SKIP LOCKED（工作队列模式）

```sql
-- 跳过已被其他事务锁定的行，获取一个"可用的"库存批次
BEGIN;
SELECT * FROM t_lock_test
    WHERE qty > 0
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

-- 如果返回了行（假设是 id=3），执行扣减
UPDATE t_lock_test SET qty = qty - 1 WHERE id = 3 AND qty > 0;
COMMIT;
```

```python
# 应用层 SKIP LOCKED 库存扣减
cursor.execute("""
    SELECT id, qty FROM t_lock_test
    WHERE qty > 0
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
""")
row = cursor.fetchone()

if row is None:
    return "库存已售罄"  # 所有行都被锁或库存为 0

cursor.execute("""
    UPDATE t_lock_test SET qty = qty - 1
    WHERE id = %s AND qty > 0
""", (row['id'],))
connection.commit()
return f"扣减成功，批次: {row['id']}"
```

#### 锁排查命令速查

```sql
-- 查看当前锁等待（实时）
SELECT * FROM information_schema.data_lock_waits;

-- 查看死锁历史
SELECT * FROM information_schema.deadlocks;

-- 查看集群所有活跃连接及等待状态
SELECT instance, id, user, db, command, time, state, substring(info, 1, 80) AS query
FROM information_schema.cluster_processlist
WHERE command != 'Sleep'
ORDER BY time DESC;

-- 查看悲观锁相关配置
SHOW VARIABLES LIKE '%lock%';
SELECT @@tidb_txn_mode;  -- 应为 'pessimistic'（NOWAIT/SKIP LOCKED 的前提）
```

### 三种方案对比

| 特性 | FOR UPDATE（bad） | FOR UPDATE NOWAIT | FOR UPDATE SKIP LOCKED |
|------|-------------------|-------------------|------------------------|
| 锁不可用时的行为 | 阻塞等待 | **立即报错** | **跳过该行** |
| 等待时间 | 0 ~ 50s | 0 | 0 |
| 连接占用 | 等待期间持续占用 | 立即释放 | 立即释放 |
| 连接池影响 | **严重（易耗尽）** | 无影响 | 无影响 |
| 结果确定性 | 必定获取请求的行 | 可能失败 | 可能返回空/不完整 |
| 应用层复杂度 | 低（无额外处理） | 中（需重试/降级逻辑） | 中（需处理跳过逻辑） |
| 吞吐量 | 低（串行化） | 中（依赖重试） | **高（并行化）** |
| 适用场景 | 低并发、必须等待 | 快速失败、降级可用 | 队列消费、库存分片 |

<ExplainCompare
  :bad="{ behavior: 'FOR UPDATE 阻塞等待', connection_pool: '连接池耗尽', throughput: '串行执行' }"
  :good="{ nowait: '立即报错，快速失败', skip_locked: '跳过已锁行，并行处理', connection_pool: '连接即用即还' }"
  improvement="从串行阻塞变为并行跳过，连接池利用率从 100% 降低到实际工作比例"
/>

---

## 避坑指南

::: warning 注意事项

1. **NOWAIT 必须有重试或降级机制**。`FOR UPDATE NOWAIT` 报错后如果不加处理直接抛给用户，用户体验不但没有改善反而更差——请求进来就被拒绝比排队等待更难接受。必须在应用层做重试（指数退避）或降级（返回"系统繁忙"）。

2. **SKIP LOCKED 结果不完整是正常行为**。不要认为 `SELECT * FROM t FOR UPDATE SKIP LOCKED` 返回的行数少于总行数是 bug。被跳过的行正在被其他事务处理中，跳过是预期行为。

3. **SKIP LOCKED 不会跳过"已修改但未提交"的行**。在一个事务中 `UPDATE qty=1` 但未提交，另一个事务的 `SELECT ... SKIP LOCKED` 会跳过该行（因为 UPDATE 也加了行锁）。但如果第一个事务尚未加锁（比如只做了快照读），它不会被跳过。

4. **NOWAIT / SKIP LOCKED 必须在悲观事务模式中使用**。TiDB 乐观事务模式下不支持这两种语法。确保 `tidb_txn_mode = 'pessimistic'`（TiDB 6.0+ 默认）。

5. **配合 ORDER BY 和 LIMIT 使用 SKIP LOCKED**。不加 ORDER BY 的情况下，SKIP LOCKED 的跳过顺序不确定。加上 `ORDER BY id LIMIT 1` 可以明确优先级，确保按顺序消费。

6. **注意 SKIP LOCKED 与 Gap Lock 的交互**。MySQL InnoDB 在 RR 隔离级别下有 Gap Lock，SKIP LOCKED 行为涉及 Gap Lock 的跳过。TiDB 没有传统 Gap Lock（通过 MVCC + 分布式锁实现），行为更简单直接。

7. **连接池大小不是越大越好**。如果用了 `FOR UPDATE` 且没有 NOWAIT/SKIP LOCKED，连接池越大反而死得越惨——更多连接会堆积在等待队列中，数据库的锁管理开销也会增大。**优化 SQL 比扩容连接池重要得多。**

8. **三种模式可以混用**。对于核心业务行（如用户余额），可以用 `FOR UPDATE NOWAIT` + 快速重试；对于库存批次等可替代资源，用 `SKIP LOCKED` 并行消费。在同一个事务中也可以：先用 SKIP LOCKED 获取可用资源，再用普通 FOR UPDATE 锁定核心记录。
:::

---

## 锁监控与预警

| 监控项 | SQL/方式 | 告警阈值 | 说明 |
|--------|---------|---------|------|
| 锁等待数量 | `SELECT COUNT(*) FROM information_schema.data_lock_waits` | > 5 | 超过 5 个锁等待需关注 |
| 锁等待时间 | `SELECT MAX(TIMESTAMPDIFF(SECOND, wait_start_time, NOW())) FROM information_schema.data_lock_waits` | > 10s | 单个锁等待超过 10 秒 |
| 长事务 | `SELECT COUNT(*) FROM cluster_processlist WHERE command='Query' AND time > 60` | > 0 | 事务执行超过 60 秒 |
| 连接池使用率 | `Active_connections / Max_connections` | > 80% | 连接池接近耗尽 |
| 阻塞事务 | DATA_LOCK_WAITS 中 BLOCKING_TRX_ID 对应的 processlist | 手动排查 | 找到长时间持锁的事务 |

---

## 本地复现

```bash
# 启动 TiDB 集群
tiup playground v7.5.1 --db 1 --kv 3

# 运行本案例
./scripts/run-case.sh 99-tidb-lock-deep --ver tidb

# 跳过造数据重跑
./scripts/run-case.sh 99-tidb-lock-deep --ver tidb --no-seed
```

复现锁等待实验（需要两个终端）：

**终端 1（会话A，持锁）**：
```sql
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- 保持事务不提交
```

**终端 2（会话B，观察行为差异）**：
```sql
-- 实验1: 普通 FOR UPDATE（阻塞等待）
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;
-- 观察: 阻塞等待，state = 'Waiting for pessimistic lock'

-- 实验2: FOR UPDATE NOWAIT（立即报错）
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE NOWAIT;
-- 观察: ERROR 3572

-- 实验3: FOR UPDATE SKIP LOCKED（跳过）
BEGIN;
SELECT * FROM t_lock_test FOR UPDATE SKIP LOCKED;
-- 观察: 返回 id=2,3,4,5（跳过被锁的 id=1）
```

在终端 2 等待期间，从终端 3 执行排查 SQL：
```sql
SELECT * FROM information_schema.data_lock_waits;
SELECT instance, id, time, state FROM information_schema.cluster_processlist WHERE command != 'Sleep';
```

::: tip 对比实验建议
建议先在终端 2 依次执行三种 `FOR UPDATE` 变体，对比它们的返回时间和行为差异。`FOR UPDATE` 会阻塞 50s（默认超时），而 `NOWAIT` 和 `SKIP LOCKED` 会立即返回——这三者的体验差异是理解本案例的最佳方式。
:::
