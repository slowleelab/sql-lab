# EXPLAIN 参考结果 - good.sql (短超时 + 短事务 + 应用层重试)

## MySQL 8.0（配合 setup-good.sql 设置 innodb_lock_wait_timeout=5）

```
-- EXPLAIN UPDATE t_concurrent_counter SET counter_value=counter_value+1 WHERE id=1;
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table                | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_concurrent_counter | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | Using where |
+----+-------------+----------------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

```
-- 确认超时设置已生效
SELECT @@innodb_lock_wait_timeout;
+----------------------------+
| @@innodb_lock_wait_timeout |
+----------------------------+
|                          5 |
+----------------------------+
```

## 关键改进

| 维度 | bad.sql | good.sql |
|------|---------|----------|
| innodb_lock_wait_timeout | 50 秒（默认） | **5 秒** |
| 事务时长 | 长（持锁不释放） | **短（快速提交）** |
| 超时后处理 | 直接报错 | **应用层重试** |
| 连接占用 | 最长 50 秒 | 最长 5 秒 |

## 为什么更好

### 短事务 + 短超时时间线

```
时间线   会话A（短事务）                  会话B（短超时+重试）
  T0     BEGIN;
  T1     UPDATE id=1;
  T2     COMMIT;   -- 快速释放行锁（<100ms）
  T3                                      BEGIN;
  T4                                      UPDATE id=1;  -- 锁已释放，直接成功
  T5                                      COMMIT;
```

正常情况下短事务快速提交，锁持有时间极短，几乎不会冲突。

### 冲突时的快速失败与重试

```
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

- 5 秒超时快速失败，连接不被长时间占用
- 应用层捕获 1205 错误后重试，对用户透明

### 应用层重试逻辑

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

### 相关超时参数配置

```sql
-- 锁等待超时（行锁等待，影响 UPDATE/DELETE）
SET GLOBAL innodb_lock_wait_timeout = 5;       -- 建议 5~10 秒

-- 死锁检测超时（InnoDB 内部死锁检测回滚时间）
SET GLOBAL innodb_deadlock_detect = ON;        -- 默认开启死锁检测

-- 事务空闲超时（事务长时间无活动自动回滚）
SET SESSION innodb_lock_wait_timeout = 5;

-- 查看所有锁相关参数
SHOW VARIABLES LIKE 'innodb_%lock%';
SHOW VARIABLES LIKE 'innodb_%timeout%';
```

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| innodb_lock_wait_timeout | 50 | 5~10 | 行锁等待超时 |
| innodb_deadlock_detect | ON | ON | 死锁自动检测 |
| lock_wait_timeout | 31536000 | 60 | 元数据锁超时 |

## 量化对比

| 指标 | bad.sql（50s超时） | good.sql（5s超时+重试） |
|------|-------------------|----------------------|
| 最大等待时间 | 50 秒 | 5 秒 |
| 连接占用 | 最长 50 秒 | 最长 5 秒 |
| 超时后恢复 | 手动 | 自动重试 |
| 雪崩风险 | 高 | 低 |

## 避坑指南

1. **缩短事务**：事务越小越好，避免在事务中做远程调用、文件 IO 等慢操作
2. **合理超时**：innodb_lock_wait_timeout 建议 5~10 秒，平衡等待与快速失败
3. **应用层重试**：捕获 1205（锁超时）和 1213（死锁）错误，自动重试 2~3 次
4. **退避策略**：重试时加入退避（如 100ms、200ms），避免惊群
5. **监控锁等待**：定期检查 `innodb_trx` 和 `data_lock_waits`，发现长事务及时处理
6. **连接池超时对齐**：连接池的 wait_timeout 应大于 innodb_lock_wait_timeout，避免连接先断

## 5.7 vs 8.0 差异

- 超时机制和错误码一致
- 8.0 的 `data_lock_waits` 视图更便于监控锁等待
- 8.0 可在高并发下关闭死锁检测（`innodb_deadlock_detect=OFF`）配合短超时，降低 CPU 开销
