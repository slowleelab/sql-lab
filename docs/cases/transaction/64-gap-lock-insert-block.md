# 间隙锁导致插入阻塞

<CaseMeta difficulty="⭐⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['间隙锁', 'RR隔离', '插入阻塞', '锁范围']" />

## 1205 阻塞：间隙锁把插入也卡死
金融账户系统中，事务A执行范围查询 `SELECT ... WHERE id BETWEEN 10 AND 20 FOR UPDATE` 锁定一批账户进行对账。与此同时，事务B尝试向该范围插入一个新账户（id=15），结果被长时间阻塞，最终报 `ERROR 1205 (HY000): Lock wait timeout exceeded`。

```sql
-- 会话A：范围查询加排他锁，锁定 [10, 20] 区间及间隙
BEGIN;
SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
-- 加锁：id=10 记录锁 + (10,20) 间隙锁 + id=20 next-key锁
-- 不提交，保持锁

-- 会话B：尝试向间隙内插入数据
BEGIN;
INSERT INTO t_account (id, account_no, balance) VALUES (15, 'ACC0015', 500.00);
-- ❌ 被阻塞！等待会话A释放间隙锁
-- 超时后报错：ERROR 1205 (HY000): Lock wait timeout exceeded
```

明明 id=15 是一条**全新的、不存在的记录**，为什么插入会被阻塞？因为 RR 隔离级别下，范围 `FOR UPDATE` 不只锁命中的行，还会锁住行与行之间的**间隙**，防止幻读。id=15 落在间隙 (10, 20) 内，被间隙锁挡住。

::: warning 真实场景
这是 RR 隔离级别（MySQL 默认）下最常见的"隐形锁"问题。对账、批量更新、范围校验等场景一旦用了范围 `FOR UPDATE`，就会锁住区间内的所有空隙，导致其他事务无法插入新数据。表现为线上偶发的"插入卡住"或"锁等待超时"，排查时只看 EXPLAIN 看不出端倪，必须分析锁类型。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: RR隔离级别下范围查询 FOR UPDATE 加间隙锁，阻塞插入
-- 事务A对 id BETWEEN 10 AND 20 加范围锁，会锁定间隙 (10, 20)
-- 事务B尝试 INSERT id=15（落在间隙内）会被阻塞直到超时
--
-- 复现步骤（需两个会话，RR 隔离级别，MySQL 默认）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
--     -- 加锁：id=10 记录锁 + (10,20) 间隙锁 + id=20 next-key锁
--     -- 不提交，保持锁
--
--   会话B（被阻塞）:
--     BEGIN;
--     INSERT INTO t_account (id, account_no, balance) VALUES (15, 'ACC0015', 500.00);
--     -- ❌ 被阻塞！等待会话A释放间隙锁
--     -- 超时后报错：ERROR 1205 (HY000): Lock wait timeout exceeded

BEGIN;

-- 范围查询加排他锁：锁定 [10, 20] 区间及间隙 (10,20)
SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;

-- 此时事务A持有间隙锁，不 COMMIT，切换到会话B执行 INSERT 即可复现阻塞
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
| id | select_type | table     | partitions | type  | possible_keys | key     | key_len | ref  | rows | filtered | Extra |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
|  1 | SIMPLE      | t_account | NULL       | range | PRIMARY       | PRIMARY | 8       | NULL |    2 |   100.00 | NULL  |
+----+-------------+-----------+------------+-------+---------------+---------+---------+------+------+----------+-------+
```

查看 `FOR UPDATE` 实际加的锁（8.0 `performance_schema.data_locks`）：

```
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

### 为什么慢

关键不在 EXPLAIN（`type=range`，`rows=2`，看似正常），而在于 `lock_mode` 列出现了 **`X,GAP`**--间隙锁。

```
RR 隔离级别的间隙锁机制：

WHERE id BETWEEN 10 AND 20 FOR UPDATE 加锁范围：
  - id=10  ：记录锁（X,REC_NOT_GAP）
  - (10,20)：间隙锁（X,GAP）-- 锁定 10 和 20 之间的所有空隙
  - id=20  ：next-key 锁（X）-- 记录锁 + 后方间隙锁

插入阻塞复现：
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

间隙锁的影响范围：

| 操作 | 是否被阻塞 | 原因 |
|------|-----------|------|
| INSERT id=15 | **是** | 15 在间隙 (10,20) 内 |
| INSERT id=12 | **是** | 12 在间隙 (10,20) 内 |
| UPDATE id=10 | **是** | 10 的记录锁被持有 |
| UPDATE id=5 | 否 | 5 不在锁范围内 |
| INSERT id=25 | 否 | 25 超过 20，不在该间隙 |

::: tip 核心认知
RR 下范围 `FOR UPDATE` 的锁范围远大于命中行数。它不只锁行，还锁间隙，目的是防幻读--但这会阻塞其他事务向间隙内插入数据。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 缩小锁范围或使用 RC 隔离级别避免间隙锁
-- 方案一：精确等值查询 FOR UPDATE，只锁定命中的行（记录锁），不加间隙锁
-- 方案二：配合 setup-good.sql 切换到 RC 隔离级别，消除间隙锁
--
-- 复现验证（配合 setup-good.sql 切到 RC）：
--
--   会话A: SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
--          BEGIN;
--          SELECT * FROM t_account WHERE id BETWEEN 10 AND 20 FOR UPDATE;
--          -- RC 下只加记录锁（id=10, id=20），不加间隙锁
--
--   会话B: BEGIN;
--          INSERT INTO t_account (id, account_no, balance) VALUES (15, 'ACC0015', 500.00);
--          -- ✅ 插入成功！不受阻塞（间隙未被锁）

BEGIN;

-- 精确等值查询加锁：只锁 id=10 这一行（记录锁），不影响间隙插入
SELECT * FROM t_account WHERE id = 10 FOR UPDATE;

COMMIT;
```

配合 `setup-good.sql` 切换到 RC 隔离级别：

```sql
-- setup-good.sql: 切换到 READ COMMITTED 隔离级别
-- RC 隔离级别下，FOR UPDATE 只加记录锁，不加间隙锁，避免插入阻塞
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

### 原理

**方案一：RC 隔离级别**

RC（READ COMMITTED）不加间隙锁，`FOR UPDATE` 只对实际命中的行加记录锁。id=10、id=20 各加一个记录锁，间隙 (10,20) **不加锁**，事务B 插入 id=15 直接成功。

```
RC 下 FOR UPDATE 的锁（8.0 performance_schema.data_locks）：
+-------------+------------+-----------+-----------+-----------+
| object_name | index_name | lock_type | lock_mode | lock_data |
+-------------+------------+-----------+-----------+-----------+
| t_account   | NULL       | TABLE     | IX        | NULL      |
| t_account   | PRIMARY    | RECORD    | X,REC_NOT_GAP | 10    |  -- 仅记录锁
| t_account   | PRIMARY    | RECORD    | X,REC_NOT_GAP | 20    |  -- 仅记录锁
+-------------+------------+-----------+-----------+-----------+
注意：RC 下没有 X,GAP 间隙锁！
```

**方案二：精确等值查询**

`WHERE id = 10 FOR UPDATE`（唯一索引等值命中）只加记录锁。RR 下唯一索引等值命中记录时也是记录锁而非 next-key lock，不触碰间隙，不影响插入。

RC vs RR 的权衡：

| 维度 | RR（默认） | RC |
|------|-----------|-----|
| 幻读 | 防止（间隙锁） | 允许 |
| 锁范围 | 大（含间隙） | 小（仅记录） |
| 并发插入 | 易阻塞 | 不阻塞 |
| 死锁概率 | 较高 | 较低 |
| 适用场景 | 强一致性 | 高并发、业务可容忍幻读 |

### 对比

| | bad.sql（RR 范围） | good.sql（RC / 精确等值） |
|---|---|---|
| lock_mode | `X` + `X,GAP`（含间隙锁） | `X,REC_NOT_GAP`（仅记录锁） |
| 插入 id=15 | 阻塞 | **不阻塞** |
| 锁范围 | 区间 + 间隙 | 仅命中行 |
| 幻读防护 | 有（间隙锁） | 无（业务层保证） |
| 死锁风险 | 高 | 低 |

<ExplainCompare
  :bad="{ type: 'range', key: 'PRIMARY', rows: '2', Extra: 'X + X,GAP 间隙锁阻塞插入' }"
  :good="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: 'X,REC_NOT_GAP 仅记录锁不阻塞' }"
  improvement="消除间隙锁，插入不再阻塞，并发吞吐显著提升"
/>

## 避坑指南

::: warning 注意事项

1. **高并发场景优先 RC**：RC 不加间隙锁，插入不阻塞，死锁概率低；幻读由业务唯一索引或版本号兜底。

2. **RR 下避免范围 FOR UPDATE**：范围条件会加大量间隙锁，尽量用精确等值替代。

3. **缩短持锁事务**：FOR UPDATE 后尽快 COMMIT，减少锁持有时间。

4. **按主键精确加锁**：`WHERE id = N FOR UPDATE`（唯一索引等值命中）只加记录锁。

5. **8.0 可查锁详情**：`performance_schema.data_locks` 精确查看 `lock_mode` 判断是否有 GAP。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| RR 间隙锁机制 | 有（默认行为） | 有（默认行为） |
| RC 消除间隙锁 | ✅ 有效 | ✅ 有效 |
| 锁信息查看 | `SHOW ENGINE INNODB STATUS` 的 RECORD LOCKS 段 | `performance_schema.data_locks` 直观查看 lock_mode |
| 精确等值防间隙锁 | ✅ 有效 | ✅ 有效 |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 64-gap-lock-insert-block

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 64-gap-lock-insert-block --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 64-gap-lock-insert-block --no-seed
```
