# 乐观锁与悲观锁对比

<CaseMeta difficulty="⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['乐观锁', '悲观锁', '版本号', '并发扣减']" />

## 发现同一商品的扣减请求全部串行排队
秒杀活动的库存扣减场景，使用悲观锁 `SELECT ... FOR UPDATE` 先锁行再扣减。单测时一切正常，但压测时发现同一商品的扣减请求全部串行排队，TPS 只有几百，行锁持有时间 = 网络往返 + 应用层逻辑 + UPDATE 执行，高并发下等待严重。

```sql
-- 悲观锁方式：SELECT FOR UPDATE 锁行后更新
BEGIN;
-- 步骤1: 悲观锁查询，锁定 product_id=1 的行（持锁直到 COMMIT）
SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1 FOR UPDATE;
-- 步骤2: 扣减库存（应用层在拿到 stock 值后判断 >0 再执行）
UPDATE t_stock_lock SET stock = stock - 1, updated_at = NOW() WHERE product_id = 1;
COMMIT;
-- 问题：步骤1~COMMIT 期间行锁不释放，并发请求全部排队，吞吐量低
```

事务A 在持锁期间（从 FOR UPDATE 到 COMMIT），事务B、C 的 FOR UPDATE 全部等待，形成串行化执行。行锁持有越久，并发吞吐越低。

::: warning 真实场景
库存扣减、余额更新、计数器累加--这些"读后写"场景是并发控制的经典战场。悲观锁简单可靠但吞吐有上限，乐观锁通过版本号 CAS 实现无锁读 + 瞬间加锁更新，在读多写少或冲突概率低的场景下吞吐显著更高。选错锁策略，要么吞吐上不去，要么重试爆炸。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 悲观锁方式 - SELECT FOR UPDATE 锁行后更新
-- 整个事务期间持有行锁，其他事务必须等待，高并发下吞吐受限
--
-- 悲观锁流程：
--   1. BEGIN
--   2. SELECT stock FROM t_stock_lock WHERE product_id=1 FOR UPDATE;  -- 加行锁，读到 stock 值
--   3. 应用层判断 stock > 0
--   4. UPDATE t_stock_lock SET stock=stock-1 WHERE product_id=1;      -- 扣减
--   5. COMMIT  -- 释放行锁
--
-- 问题：步骤2~5期间行锁不释放，并发请求全部排队，吞吐量低

BEGIN;

-- 步骤1: 悲观锁查询，锁定 product_id=1 的行（持锁直到 COMMIT）
SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1 FOR UPDATE;

-- 步骤2: 扣减库存（应用层在拿到 stock 值后判断 >0 再执行）
UPDATE t_stock_lock
SET stock = stock - 1, updated_at = NOW()
WHERE product_id = 1;

COMMIT;
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1 FOR UPDATE;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+

-- EXPLAIN UPDATE t_stock_lock SET stock=stock-1 WHERE product_id=1;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra       |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | Using where |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
```

查询本身走唯一索引等值定位（`type=const`，`rows=1`），性能没问题。**问题在于悲观锁的持锁时间长、并发吞吐低**。

### 为什么慢

```
悲观锁的执行时间线：

时间线   事务A                       事务B                       事务C
  T1     BEGIN;
  T2     SELECT ... FOR UPDATE;      -- 锁定 product_id=1
  T3                                BEGIN;
  T4                                SELECT ... FOR UPDATE;      -- ❌ 等待行锁
  T5                                                            BEGIN;
  T6                                                            SELECT ... FOR UPDATE;  -- ❌ 等待行锁
  T7     UPDATE stock-1;
  T8     COMMIT;   -- 释放锁
  T9                                获取锁，UPDATE, COMMIT;
  T10                                                           获取锁，UPDATE, COMMIT;
```

- 事务A 在 T2~T8 期间持有行锁，期间事务B、C 全部排队等待
- **串行化执行**：同一商品的扣减请求只能一个接一个处理
- 行锁持有时间 = 网络往返 + 应用层逻辑 + UPDATE 执行，高并发下等待严重

::: tip 核心认知
悲观锁的吞吐瓶颈不在 SQL 本身，而在持锁时间。整个事务期间行锁不释放，并发请求被迫串行。缩短持锁时间或改用乐观锁（仅 UPDATE 瞬间加锁）是提升吞吐的关键。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 乐观锁方式 - 原子条件更新，无需显式加锁
-- 利用 version 版本号做 CAS（Compare-And-Swap），冲突时 affected_rows=0 重试
--
-- 乐观锁流程：
--   1. SELECT stock, version FROM t_stock_lock WHERE product_id=1;  -- 无锁读（快照）
--   2. 应用层判断 stock > 0
--   3. UPDATE ... SET stock=stock-1, version=version+1
--        WHERE product_id=1 AND version=原版本 AND stock>0;          -- 原子 CAS
--   4. 若 affected_rows=0 表示版本已变（被其他事务改过），重试步骤1
--
-- 优势：不持有长锁，并发事务可并行读取，仅 UPDATE 瞬间加行锁

-- 步骤1: 无锁读取当前库存与版本（应用层保存 version 值）
SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1;

-- 步骤2: 乐观锁原子扣减（假设读到的 version=0，传入 WHERE version=0）
-- 若并发事务已修改，version 不匹配则 affected_rows=0，应用层重试
UPDATE t_stock_lock
SET stock = stock - 1,
    version = version + 1,
    updated_at = NOW()
WHERE product_id = 1
  AND version = 0
  AND stock > 0;
```

### 原理

乐观锁把"读"和"写"解耦：步骤1的 SELECT **不加锁**（快照读），多个事务可并行读取；仅步骤2的 UPDATE 瞬间加行锁，持锁时间极短（微秒级）。冲突时 `affected_rows=0`，应用层重试。

```
乐观锁的执行时间线：

时间线   事务A                          事务B                          事务C
  T1     SELECT stock,version;          -- 无锁读（快照），version=0
  T2                                    SELECT stock,version;          -- 无锁读，version=0
  T3                                                                   SELECT stock,version;  -- 无锁读
  T4     UPDATE ... WHERE version=0;    -- 加行锁，CAS 成功
         -> stock-1, version=1          -> affected_rows=1
         -> 释放锁
  T5                                    UPDATE ... WHERE version=0;    -- 加行锁，version 已变
                                        -> affected_rows=0（冲突！）
  T6                                    -- 重试：SELECT（读到 version=1）
  T7                                    UPDATE ... WHERE version=1;    -- CAS 成功
```

应用层重试逻辑：

```python
# 乐观锁扣减（含重试）
for attempt in range(max_retry=3):
    row = db.query("SELECT stock, version FROM t_stock_lock WHERE product_id=1")
    if row.stock <= 0:
        return "库存不足"
    affected = db.execute("""
        UPDATE t_stock_lock
        SET stock = stock - 1, version = version + 1, updated_at = NOW()
        WHERE product_id = 1 AND version = %s AND stock > 0
    """, (row.version,))
    if affected == 1:
        return "扣减成功"
    # affected=0 表示版本已变，重试
# 重试次数用尽
return "并发冲突，请重试"
```

乐观锁 vs 悲观锁对比：

| 维度 | 悲观锁（bad） | 乐观锁（good） |
|------|-------------|---------------|
| 读操作 | FOR UPDATE 加锁 | **无锁快照读** |
| 行锁持有 | 整个事务期间 | 仅 UPDATE 瞬间 |
| 并发读 | 串行 | **并行** |
| 冲突处理 | 等待（排队） | 重试（CAS） |
| 死锁风险 | 较高 | 极低 |
| 适合场景 | 写冲突频繁 | 读多写少/冲突少 |

### 对比

| | 悲观锁 | 乐观锁（冲突率低） | 乐观锁（冲突率高） |
|---|---|---|---|
| 行锁持有时间 | 长（整个事务） | 极短（UPDATE瞬间） | 极短+重试 |
| 并发吞吐 | 低（串行） | **高** | 中（重试开销） |
| 死锁风险 | 中 | **极低** | 极低 |
| 实现复杂度 | 简单 | 需重试逻辑 | 需重试逻辑 |

<ExplainCompare
  :bad="{ type: 'const', key: 'uk_product', rows: '1', Extra: 'FOR UPDATE 持锁整个事务，并发串行' }"
  :good="{ type: 'const', key: 'uk_product', rows: '1', Extra: '无锁读+CAS更新，仅UPDATE瞬间加锁' }"
  improvement="行锁持有从整个事务缩短到 UPDATE 瞬间，并发读并行，吞吐显著提升"
/>

## 避坑指南

::: warning 注意事项

1. **冲突率高时用悲观锁**：乐观锁重试次数过多反而比悲观锁慢，写冲突频繁的场景应选悲观锁。

2. **version 字段必须有索引**：`WHERE version=N` 需要走索引定位，否则 UPDATE 退化为扫描。

3. **重试次数要限制**：乐观锁重试应有上限（如 3 次），避免无限重试耗尽资源。

4. **stock>0 条件不可省**：即使 version 匹配，也要检查 stock>0 防止扣成负数。

5. **悲观锁要短事务**：若用悲观锁，尽快 COMMIT 释放锁，不要在锁内做耗时操作。

6. **混合策略**：热点商品用悲观锁（冲突高），普通商品用乐观锁（冲突低）。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 悲观锁 FOR UPDATE | 加行锁直到 COMMIT | 一致 |
| 乐观锁 CAS 机制 | 依赖 affected_rows 判断冲突 | 一致 |
| 锁持有观察 | `SHOW ENGINE INNODB STATUS` | `performance_schema.data_locks` |
| SKIP LOCKED | ❌ 不支持 | ✅ 支持（悲观锁队列场景优化） |

::: tip 8.0 SKIP LOCKED
8.0 新增 `SKIP LOCKED` 语法，可用于悲观锁的队列场景，跳过被锁行不等待：

```sql
SELECT * FROM t_stock_lock WHERE product_id = 1 FOR UPDATE SKIP LOCKED;
```
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 66-optimistic-vs-pessimistic-lock

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 66-optimistic-vs-pessimistic-lock --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 66-optimistic-vs-pessimistic-lock --no-seed
```
