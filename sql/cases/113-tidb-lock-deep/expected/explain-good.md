# EXPLAIN 参考结果 - good.sql（NOWAIT / SKIP LOCKED）

## TiDB 悲观模式（5 行测试数据）

---

## 一、FOR UPDATE NOWAIT

### 会话A: 先持有 id=1 的锁

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

会话A 持有 id=1 的行锁（未提交）。

---

### 会话B: FOR UPDATE NOWAIT——立即报错

```sql
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE NOWAIT;
```

```
ERROR 3572 (HY000): Statement aborted because lock(s) could not be acquired
                    immediately and NOWAIT is set.
```

| 行为 | 普通 FOR UPDATE | FOR UPDATE NOWAIT |
|------|----------------|-------------------|
| 锁不可用 | 阻塞等待（最多 50s） | **立即返回错误** |
| 错误码 | ERROR 1205（超时） | ERROR 3572（NOWAIT 拒绝） |
| 等待时间 | 0 ~ 50s | **0（零等待）** |
| 连接状态 | `Waiting for pessimistic lock` | 返回结果/报错后释放连接 |
| 适用场景 | 必须等待 | 快速失败 + 重试 / 降级 |

---

## 二、FOR UPDATE SKIP LOCKED

### 会话A: 持有 id=1 和 id=2 的锁

```sql
BEGIN;
SELECT * FROM t_lock_test WHERE id IN (1, 2) FOR UPDATE;
```

```
+----+-----------+------+
| id | item_name | qty  |
+----+-----------+------+
|  1 | alice     |  100 |
|  2 | bob       |  100 |
+----+-----------+------+
```

会话A 持有 id=1 和 id=2 的行锁。

---

### 会话B: SKIP LOCKED——跳过已锁定的行

```sql
BEGIN;
SELECT * FROM t_lock_test FOR UPDATE SKIP LOCKED;
```

```
+----+-----------+------+
| id | item_name | qty  |
+----+-----------+------+
|  3 | charlie   |  100 |
|  4 | dave      |  100 |
|  5 | eve       |  100 |
+----+-----------+------+
```

- id=1,2 被会话A 锁定，被 SKIP LOCKED 跳过
- 返回 id=3,4,5（未锁定的行），并对其加锁
- **零等待**：被跳过的行不会阻塞查询

---

### SKIP LOCKED 的 EXPLAIN 输出

```sql
EXPLAIN SELECT * FROM t_lock_test WHERE qty > 0 ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
```

```
+---------------------+----------+-----------+---------------+---------------+-------------------------------+
| id                  | estRows  | task      | access object | operator info | ...                           |
+---------------------+----------+-----------+---------------+---------------+-------------------------------+
| Projection_7        | 1.00     | root      |               | t_lock_test...|                               |
| └─Limit_11          | 1.00     | root      |               | offset:0,count:1             |
|   └─TableReader_15  | 1.00     | root      |               | data:Limit_14                |
|     └─Limit_14      | 1.00     | cop[tikv] |               | offset:0,count:1             |
|       └─Selection_13| 1.00     | cop[tikv] |               | gt(t_lock_test.qty, 0)      |
|         └─TableFullScan_12| 5.00| cop[tikv]| table:t_lock_test| keep order:true             |
+---------------------+----------+-----------+---------------+---------------+-------------------------------+
```

EXPLAIN 输出与普通 `SELECT FOR UPDATE` 一致，`SKIP LOCKED` 不体现在执行计划中——它在 TiKV 层运行时动态跳过已锁定的行。

---

## 三种 FOR UPDATE 行为对比总表

| 特性 | FOR UPDATE | FOR UPDATE NOWAIT | FOR UPDATE SKIP LOCKED |
|------|-----------|-------------------|------------------------|
| 锁不可用时 | **阻塞等待** | **立即报错** | **跳过该行** |
| 等待时间 | 0 ~ 50s（取决于超时） | 0 | 0 |
| 返回结果 | 等待后获得锁 | ERROR 3572 | 仅未锁定的行 |
| 结果完整性 | 获取请求的所有行 | 无（报错） | 不完整（跳过被锁行） |
| 连接占用 | 等待期间占用连接 | 瞬时 | 瞬时 |
| 适用场景 | 必须操作特定行 | 快速失败 + 重试 | 队列消费 / 库存扣减 |
| 事务要求 | 必须在事务中 | 必须在事务中 | 必须在事务中 |
| TiDB 支持 | 支持 | 支持 | 支持 |
| MySQL 支持 | 所有版本 | 8.0+ | 8.0+ |

---

## SKIP LOCKED 在秒杀库存扣减中的应用

### 场景：一个商品有 5 个库存批次，100 个并发请求争抢

```sql
-- 每个并发请求执行：
BEGIN;
-- SKIP LOCKED 自动跳过已被其他请求锁定的批次
SELECT * FROM t_lock_test
    WHERE qty > 0
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

-- 如果返回了行，则进行扣减
-- UPDATE t_lock_test SET qty = qty - 1 WHERE id = ? AND qty > 0;
-- 如果返回空结果，说明所有批次都在被处理中（或库存已耗尽）
COMMIT;
```

### 执行时间线

```
批次  id=1         id=2         id=3         id=4         id=5
      qty=100      qty=100      qty=100      qty=100      qty=100

请求A: SELECT ... SKIP LOCKED → 获取 id=1，对其加锁，扣减
请求B: SELECT ... SKIP LOCKED → id=1 被锁（跳过）→ 获取 id=2，扣减
请求C: SELECT ... SKIP LOCKED → id=1,2 被锁（跳过）→ 获取 id=3，扣减
请求D: SELECT ... SKIP LOCKED → id=1,2,3 被锁（跳过）→ 获取 id=4，扣减
请求E: SELECT ... SKIP LOCKED → id=1,2,3,4 被锁（跳过）→ 获取 id=5，扣减
请求F: SELECT ... SKIP LOCKED → 全部被锁 → 返回空结果（库存耗尽/重试）
```

- 5 个并发请求同时执行，各自获取不同的批次，**互不阻塞**
- 如果没有 SKIP LOCKED，5 个请求都会阻塞在 `FOR UPDATE id=1` 上，串行执行
- 吞吐量从串行（5 个请求排队）提升到并行（5 个请求同时处理）

### 注意事项

1. **结果不完整是预期行为**：SKIP LOCKED 跳过被锁定的行，应用层需处理"返回行数少于预期"的情况
2. **结合 ORDER BY 和 LIMIT 使用**：明确获取优先级（如 `ORDER BY id LIMIT 1`）
3. **不是替代方案而是互补**：NOWAIT 适合快速失败路径，SKIP LOCKED 适合工作队列模式
4. **MySQL 8.0 vs TiDB**：两者对 SKIP LOCKED 的语义一致，均跳过被其他事务锁定的行；TiDB 在分布式环境中通过 TiKV 协同实现
5. **连接池释放**：NOWAIT/SKIP LOCKED 都不占用连接等待，避免连接池耗尽
