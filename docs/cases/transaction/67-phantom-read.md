# 幻读问题与解决

<CaseMeta difficulty="⭐⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['幻读', '间隙锁', 'RR隔离', 'MVCC']" />

## 场景痛点

交易风控系统中，事务A 先查询某个金额区间内是否有交易记录（`COUNT(*) = 0`），据此判断"该区间无异常交易"并执行后续操作。事务B 在此期间插入了一条该区间的交易记录并提交。事务A 后续用 `FOR UPDATE` 或 `UPDATE` 触发当前读时，突然看到了事务B 插入的"幻影行"，导致业务逻辑前后矛盾。

```sql
-- 会话A（RR 隔离级别）：
BEGIN;
-- 第一次查询：范围 5000~6000 内 0 行
SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
-- 结果：0

-- （此时会话B 插入一行 amount=5500 并 COMMIT）

-- 第二次普通 SELECT（快照读）：仍是 0（快照未变）
SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
-- 结果：0（快照读看不到新插入）

-- 但当前读会看到幻影行：
SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
-- 结果：1（当前读看到会话B插入的 5500）=> 幻读！
```

很多人以为 RR（可重复读）已经解决了幻读，实际上 RR 只保证**快照读**一致，一旦事务内出现**当前读**（FOR UPDATE / UPDATE / DELETE），就会看到其他事务新提交的数据，产生幻读。

::: warning 真实场景
"先查后写"是业务中最常见的模式：先 SELECT 判断条件，再 UPDATE/INSERT 操作。在 RR 下，如果判断用快照读、操作用当前读，两次看到的范围不一致就会导致逻辑错误--比如"查到无记录所以插入"，结果插入时发现已被其他事务插入；或"查到 0 条所以批量更新"，结果 UPDATE 命中了幻影行。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 普通快照读在事务中两次查询同一范围，演示幻读现象
-- RR 隔离级别下，普通 SELECT 是快照读，同一事务内读到的快照一致
-- 但当前读（UPDATE/DELETE/SELECT FOR UPDATE）会看到最新数据，导致幻读
--
-- 幻读复现（需两个会话，RR 隔离级别）：
--
--   会话A:
--     BEGIN;
--     -- 第一次查询：范围 5000~6000 内 0 行
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0
--
--   会话B:
--     INSERT INTO t_transaction_log (tx_amount) VALUES (5500.00);
--     COMMIT;
--
--   会话A:
--     -- 第二次普通 SELECT（快照读）：仍是 0（快照未变）
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0（快照读看不到新插入）
--
--     -- 但当前读会看到幻影行：
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
--     -- 结果：1（当前读看到会话B插入的 5500）=> 幻读！
--
--     -- 或 UPDATE 触发当前读：
--     UPDATE t_transaction_log SET tx_amount = tx_amount WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- Rows matched: 1（看到了幻影行）
--     COMMIT;

BEGIN;

-- 第一次查询：范围内行数
SELECT COUNT(*) AS first_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

-- （此时在会话B插入一行 amount=5500 并 COMMIT）
-- 第二次查询（普通快照读）：仍是旧快照
SELECT COUNT(*) AS second_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

-- 第三次查询（当前读 FOR UPDATE）：看到幻影行 -> 幻读
SELECT COUNT(*) AS current_read_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;

COMMIT;
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+
| id | select_type | table             | partitions | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra                    |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+
|  1 | SIMPLE      | t_transaction_log | NULL       | range | idx_amount    | idx_amount | 6       | NULL | 49803  |   100.00 | Using where; Using index |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+--------------------------+

-- EXPLAIN SELECT COUNT(*) ... FOR UPDATE;（当前读）
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
| id | select_type | table             | partitions | type  | possible_keys | key        | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_transaction_log | NULL       | range | idx_amount    | idx_amount | 6       | NULL | 49803  |   100.00 | Using where |
+----+-------------+-------------------+------------+-------+---------------+------------+---------+------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 走 idx_amount 索引范围扫描 |
| key | `idx_amount` | 使用了金额索引 |
| rows | ~49,803 | 范围内扫描行数 |
| Extra（普通读） | `Using index` | 覆盖索引，不回表 |
| Extra（FOR UPDATE） | `Using where` | 当前读，需加锁 |

查询本身走了索引，**问题不在性能，而在幻读正确性**。

### 为什么慢

```
RR 下的快照读与当前读：

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

| 读类型 | 语句 | T2 结果 | T6 结果 | T7 结果 |
|--------|------|---------|---------|---------|
| 快照读 | SELECT | 0 | 0（一致） | - |
| 当前读 | SELECT FOR UPDATE | - | - | **1（幻读）** |
| 当前读 | UPDATE 触发 | - | - | matched: 1 |

- 快照读在 T2、T6 一致（MVCC 保证），看起来"没有幻读"
- 但当前读（T7）看到幻影行，业务逻辑基于快照读判断、基于当前读操作时产生不一致

幻读的危害示例：

```python
# 基于快照读的业务逻辑：
count = db.query("SELECT COUNT(*) FROM t_log WHERE amount BETWEEN 5000 AND 6000")
if count == 0:
    # 认为范围内无数据，执行某些操作
    # 但此时其他事务已插入 amount=5500
    db.execute("UPDATE t_log SET status='checked' WHERE amount BETWEEN 5000 AND 6000")
    # 结果：UPDATE 命中了幻影行（当前读），与 count==0 的判断矛盾
```

::: tip 核心认知
RR 的快照读（普通 SELECT）不会幻读，但当前读（FOR UPDATE / UPDATE / DELETE）会看到其他事务新提交的行。只要事务内混合了快照读和当前读，就可能产生幻读。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 使用 SELECT FOR UPDATE 加间隙锁防幻读，或配合 setup-good.sql 切到 SERIALIZABLE
-- 方案一：RR 下用 SELECT FOR UPDATE 加间隙锁，阻止其他事务向范围内插入
-- 方案二：SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE（自动加锁防幻读）
--
-- 防幻读复现（配合 setup-good.sql 切 SERIALIZABLE，或 RR 下用 FOR UPDATE）：
--
--   会话A:
--     BEGIN;
--     -- 加间隙锁，锁定 amount 5000~6000 范围
--     SELECT * FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;
--     -- RR: 加 next-key lock，间隙 (5000,6000) 被锁
--     -- SERIALIZABLE: 普通 SELECT 也自动加锁
--
--   会话B:
--     INSERT INTO t_transaction_log (tx_amount) VALUES (5500.00);
--     -- ❌ 被阻塞！间隙锁阻止插入
--
--   会话A:
--     -- 再次查询，范围内行数不变
--     SELECT COUNT(*) FROM t_transaction_log WHERE tx_amount BETWEEN 5000 AND 6000;
--     -- 结果：0（无幻读）
--     COMMIT;

BEGIN;

-- 加锁读：锁定范围，防止其他事务插入幻影行
SELECT * FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE;

-- 范围内行数保持一致，无幻读
SELECT COUNT(*) AS stable_count FROM t_transaction_log
WHERE tx_amount BETWEEN 5000 AND 6000;

COMMIT;
```

配合 `setup-good.sql` 切换到 SERIALIZABLE：

```sql
-- setup-good.sql: 切换到 SERIALIZABLE 隔离级别
-- SERIALIZABLE 下普通 SELECT 也会自动加共享锁+间隙锁，防止幻读
SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;
```

### 原理

`WHERE tx_amount BETWEEN 5000 AND 6000 FOR UPDATE` 在 RR 下加 next-key lock，锁定范围包括间隙 (4999.99, 6001.00)，即 5000~6000 之间的空隙。其他事务 INSERT amount=5500 落在间隙内，被间隙锁阻塞。

```
FOR UPDATE 加的锁（8.0 performance_schema.data_locks）：
+------------+-----------+-----------+-----------+
| index_name | lock_type | lock_mode | lock_data |
+------------+-----------+-----------+-----------+
| NULL       | TABLE     | IX        | NULL      |
| idx_amount | RECORD    | X         | 4999.99   |  -- next-key: (间隙,4999.99]
| idx_amount | RECORD    | X,GAP     | 6001.00   |  -- 间隙锁 (4999.99, 6001.00)
+------------+-----------+-----------+-----------+
-- 间隙 (5000, 6000) 被 X,GAP 锁定，阻止插入
```

防幻读执行时间线：

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

SERIALIZABLE 隔离级别下，**普通 SELECT 也会自动加共享锁 + 间隙锁**，无需显式 FOR UPDATE 即可防幻读，但并发性能下降明显。

防幻读方案对比：

| 方案 | 机制 | 并发影响 | 适用场景 |
|------|------|---------|---------|
| SELECT FOR UPDATE | 显式加间隙锁 | 中（锁间隙） | RR 下精确控制 |
| SERIALIZABLE | 自动加锁 | 高（所有读加锁） | 强一致性要求 |
| RC + 业务层 | 不防幻读，业务兜底 | 低 | 高并发、容忍幻读 |
| 唯一索引约束 | 防重复插入 | 低 | 仅防重复 |

### 对比

| | bad.sql（普通读） | good.sql（FOR UPDATE / SERIALIZABLE） |
|---|---|---|
| 读类型 | 快照读（无锁） | 当前读（加间隙锁） |
| lock_mode | 无锁 | `X` + `X,GAP` |
| 间隙锁 | 无 | **有**（锁定 5000~6000 间隙） |
| 插入 amount=5500 | 成功（产生幻读） | **被阻塞**（无幻读） |
| 读一致性 | 快照读一致，当前读不一致 | **完全一致** |
| 并发插入吞吐 | 高 | 降低（间隙锁阻塞） |

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_amount', rows: '49,803', Extra: '快照读无锁，当前读幻读' }"
  :good="{ type: 'range', key: 'idx_amount', rows: '49,803', Extra: 'FOR UPDATE 加 X,GAP 间隙锁防幻读' }"
  improvement="加间隙锁锁定范围，阻止其他事务插入幻影行，消除幻读"
/>

## 避坑指南

::: warning 注意事项

1. **区分快照读与当前读**：RR 下普通 SELECT 是快照读不会幻读，但 FOR UPDATE/UPDATE 是当前读会幻读。

2. **仅需防幻读时用 FOR UPDATE**：不要无脑用 SERIALIZABLE，会大幅降低并发。

3. **范围查询走索引**：FOR UPDATE 的范围条件必须走索引，否则锁全表。

4. **高并发优先 RC**：RC 无间隙锁不防幻读，但并发高、死锁少，幻读由业务唯一约束兜底。

5. **间隙锁有代价**：防幻读的代价是阻塞间隙内的插入，权衡一致性与并发性。

6. **MVCC 已解决大部分问题**：RR 的快照读已保证事务内一致，只有当前读才需关注幻读。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| RR 快照读/当前读机制 | 一致（快照读不幻读，当前读幻读） | 一致 |
| 间隙锁防幻读 | ✅ 有效 | ✅ 有效 |
| SERIALIZABLE 行为 | 所有读自动加锁 | 一致 |
| 间隙锁范围查看 | `SHOW ENGINE INNODB STATUS` 间接分析 | `performance_schema.data_locks` 精确查看 lock_mode 含 GAP |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 67-phantom-read

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 67-phantom-read --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 67-phantom-read --no-seed
```
