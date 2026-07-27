# 死锁重试与超时处理

<CaseMeta difficulty="⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['锁等待', '超时', '重试', 'innodb_lock_wait_timeout']" />

## 场景痛点

高并发计数器场景中，事务A 更新计数器后因为执行了慢操作（远程调用、大查询、GC 停顿）迟迟不 COMMIT，长时间持有行锁。事务B 尝试更新同一行，等待行锁直到默认的 `innodb_lock_wait_timeout=50` 秒后才报 `ERROR 1205 (HY000): Lock wait timeout exceeded`。50 秒的等待期间连接池连接被占用，后续请求堆积，存在雪崩风险。

```sql
-- 会话A（长事务持锁）：
BEGIN;
UPDATE t_concurrent_counter SET counter_value = counter_value + 1, thread_id = 'session-A', updated_at = NOW() WHERE id = 1;
-- 持有 id=1 行锁，不 COMMIT（模拟长事务/慢操作/网络延迟）
-- 此时执行其他慢操作（如远程调用、大查询），锁不释放

-- 会话B（等待超时）：
BEGIN;
UPDATE t_concurrent_counter SET counter_value = counter_value + 1, thread_id = 'session-B', updated_at = NOW() WHERE id = 1;
-- ❌ 等待 id=1 行锁，默认 50 秒后超时
-- ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

UPDATE 本身是主键等值更新，毫秒级完成。问题在于事务A 持锁不释放 + 默认超时 50 秒太长 + 应用层无重试机制。

::: warning 真实场景
长事务是线上事故的常见源头：一个慢 RPC 调用嵌在事务中间，行锁迟迟不释放，后续请求全部排队等待 50 秒。连接池耗尽、请求堆积、雪崩连锁。默认的 `innodb_lock_wait_timeout=50` 对互联网业务来说太长了，用户等不了 50 秒，需要快速失败 + 自动重试。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 长事务持锁不释放，另一事务等待超时
-- 事务A开启长事务持有行锁（模拟慢操作/忘记提交），事务B等待锁超时报错
--
-- 超时复现（需两个会话，默认 innodb_lock_wait_timeout=50 秒）：
--
--   会话A（长事务持锁）:
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value = counter_value + 1 WHERE id = 1;
--     -- 持有 id=1 行锁，不 COMMIT（模拟长事务/慢操作/网络延迟）
--     -- 此时执行其他慢操作（如远程调用、大查询），锁不释放
--
--   会话B（等待超时）:
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value = counter_value + 1 WHERE id = 1;
--     -- ❌ 等待 id=1 行锁，默认 50 秒后超时
--     -- ERROR 1205 (HY000): Lock wait timeout exceeded;
--     --   try restarting transaction
--
-- 问题：默认超时 50 秒太长，连接资源被长时间占用，应用层无重试逻辑

BEGIN;

-- 长事务：更新后不提交，模拟持锁不释放
UPDATE t_concurrent_counter
SET counter_value = counter_value + 1, thread_id = 'session-A', updated_at = NOW()
WHERE id = 1;

-- 此处省略慢操作（远程调用/大查询），行锁持续持有
-- 会话B 此时 UPDATE id=1 会等待超时

-- 故意不 COMMIT（演示问题，实际应在 good.sql 中缩短事务）
```

### EXPLAIN 结果

```
-- EXPLAIN UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table                | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_concurrent_counter | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+

-- 查看当前锁等待超时设置（默认 50 秒）
SELECT @@innodb_lock_wait_timeout;
+----------------------------+
| @@innodb_lock_wait_timeout |
+----------------------------+
|                         50 |
+----------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 主键等值更新，单行高效 |
| key | `PRIMARY` | 走主键索引 |
| rows | 1 | 精确命中 1 行 |
| timeout | 50 秒 | **默认超时过长** |

UPDATE 本身极快，**问题在于长事务持锁导致其他事务等待 50 秒超时**。

### 为什么慢

```
长事务持锁时间线：

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

默认超时 50 秒的危害：

- **连接资源占用**：等待 50 秒期间连接池连接被占用，可能耗尽
- **请求堆积**：后续请求排队，雪崩风险
- **用户体验差**：用户等待 50 秒才报错
- **无重试机制**：超时后直接报错，无自动恢复

超时错误的类型与处理：

| 错误码 | 含义 | 触发条件 | 处理方式 |
|--------|------|---------|---------|
| 1205 | Lock wait timeout | 行锁等待超时（innodb_lock_wait_timeout） | 重试事务 |
| 1213 | Deadlock | 死锁被回滚 | 重试事务 |
| 1206 | Lock table full | 锁内存不足 | 检查 innodb_buffer_pool |

::: tip 核心认知
锁等待超时的代价不在单条 SQL，而在 50 秒的连接占用和请求堆积。缩短超时时间 + 短事务 + 应用层重试，是治本的三件套。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 设置合理的 innodb_lock_wait_timeout + 短事务快速释放锁
-- 配合 setup-good.sql 设置 SET SESSION innodb_lock_wait_timeout=5（5秒超时）
-- 事务快速提交释放锁，超时后应用层捕获错误并重试
--
-- 优化后复现（配合 setup-good.sql）：
--
--   会话A（短事务）:
--     SET SESSION innodb_lock_wait_timeout=5;
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
--     COMMIT;  -- 快速提交，释放行锁
--
--   会话B（短超时+重试）:
--     SET SESSION innodb_lock_wait_timeout=5;
--     -- 若会话A仍持锁，5秒后超时，应用层捕获 1205 错误重试
--     BEGIN;
--     UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
--     COMMIT;

-- 短事务：快速提交释放锁，减少锁等待
BEGIN;

UPDATE t_concurrent_counter
SET counter_value = counter_value + 1, thread_id = 'session-B', updated_at = NOW()
WHERE id = 1;

COMMIT;
```

配合 `setup-good.sql` 设置超时：

```sql
-- setup-good.sql: 设置合理的锁等待超时时间（5秒）
-- 默认 innodb_lock_wait_timeout=50 秒过长，调整为 5 秒快速失败
SET SESSION innodb_lock_wait_timeout = 5;
```

### 原理

**短事务**快速提交释放锁，锁持有时间极短（<100ms），正常情况下几乎不会冲突。偶发冲突时，5 秒超时快速失败，应用层捕获 1205 错误后重试，对用户透明。

```
正常情况（短事务快速提交）：
时间线   会话A（短事务）                  会话B（短超时+重试）
  T0     BEGIN;
  T1     UPDATE id=1;
  T2     COMMIT;   -- 快速释放行锁（<100ms）
  T3                                      BEGIN;
  T4                                      UPDATE id=1;  -- 锁已释放，直接成功
  T5                                      COMMIT;
```

```
冲突时的快速失败与重试：
时间线   会话A（偶发慢）                  会话B（5秒超时+重试）
  T0     BEGIN;
  T1     UPDATE id=1;  -- 持锁
  T2                                      BEGIN;
  T3                                      UPDATE id=1;  -- 等待
  T4     -- 偶发慢操作（如 GC 停顿）       -- 等待中...
  T8                                      -- 等待满 5 秒
                                          ERROR 1205 -> 捕获，重试
  T9                                      BEGIN;  -- 重试
  T10    COMMIT;  -- 释放锁
  T11                                     UPDATE id=1;  -- 成功
  T12                                     COMMIT;
```

应用层重试逻辑：

```python
import mysql.connector
from mysql.connector import errors

def update_counter_with_retry(counter_id, max_retry=3):
    for attempt in range(max_retry):
        try:
            conn = get_connection()
            cursor = conn.cursor()
            cursor.execute("BEGIN")
            cursor.execute("""
                UPDATE t_concurrent_counter
                SET counter_value = counter_value + 1, updated_at = NOW()
                WHERE id = %s
            """, (counter_id,))
            cursor.execute("COMMIT")
            conn.close()
            return True  # 成功
        except mysql.connector.Error as e:
            # 1205: 锁等待超时, 1213: 死锁
            if e.errno in (1205, 1213):
                if attempt < max_retry - 1:
                    time.sleep(0.1 * (attempt + 1))  # 退避重试
                    continue
            raise  # 其他错误或重试次数用尽，抛出
    return False
```

相关超时参数配置：

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| innodb_lock_wait_timeout | 50 | 5~10 | 行锁等待超时 |
| innodb_deadlock_detect | ON | ON | 死锁自动检测 |
| lock_wait_timeout | 31536000 | 60 | 元数据锁超时 |

### 对比

| | bad.sql（50s超时） | good.sql（5s超时+重试） |
|---|---|---|
| innodb_lock_wait_timeout | 50 秒（默认） | **5 秒** |
| 事务时长 | 长（持锁不释放） | **短（快速提交）** |
| 超时后处理 | 直接报错 | **应用层重试** |
| 连接占用 | 最长 50 秒 | 最长 5 秒 |
| 雪崩风险 | 高 | 低 |

<ExplainCompare
  :bad="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: '默认50s超时，长事务持锁不释放' }"
  :good="{ type: 'const', key: 'PRIMARY', rows: '1', Extra: '5s超时+短事务+应用层重试' }"
  improvement="超时从 50s 降到 5s，连接占用缩短 90%，超时后自动重试恢复"
/>

## 避坑指南

::: warning 注意事项

1. **缩短事务**：事务越小越好，避免在事务中做远程调用、文件 IO 等慢操作。

2. **合理超时**：innodb_lock_wait_timeout 建议 5~10 秒，平衡等待与快速失败。

3. **应用层重试**：捕获 1205（锁超时）和 1213（死锁）错误，自动重试 2~3 次。

4. **退避策略**：重试时加入退避（如 100ms、200ms），避免惊群。

5. **监控锁等待**：定期检查 `innodb_trx` 和 `data_lock_waits`，发现长事务及时处理。

6. **连接池超时对齐**：连接池的 wait_timeout 应大于 innodb_lock_wait_timeout，避免连接先断。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| innodb_lock_wait_timeout 默认值 | 50 秒 | 50 秒 |
| 超时报错 | ERROR 1205 | ERROR 1205（一致） |
| 锁等待监控 | `information_schema.innodb_trx` | `performance_schema.data_lock_waits` 更精确 |
| innodb_deadlock_detect | 固定开启 | 可关闭（`OFF`）配合短超时降 CPU 开销 |

::: tip 8.0 锁等待监控
8.0 可通过 `performance_schema.data_lock_waits` 精确查看等待关系：

```sql
SELECT
    r.trx_id AS waiting_trx_id,
    r.trx_state AS waiting_state,
    TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS wait_seconds,
    b.trx_id AS blocking_trx_id,
    b.trx_state AS blocking_state
FROM information_schema.innodb_trx r
JOIN information_schema.innodb_trx b
  ON b.trx_id = (SELECT blocking_trx_id FROM performance_schema.data_lock_waits
                 WHERE requesting_trx_id = r.trx_id LIMIT 1);
```
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 68-deadlock-retry-timeout

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 68-deadlock-retry-timeout --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 68-deadlock-retry-timeout --no-seed
```
