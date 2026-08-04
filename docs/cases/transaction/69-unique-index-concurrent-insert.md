# 唯一索引并发插入冲突

<CaseMeta difficulty="⭐⭐" category="事务与锁" versions="5.7 & 8.0" :tags="['唯一索引', '并发插入', 'ON DUPLICATE KEY', '竞态条件']" />

## 先查后插的高并发：1062 唯一键冲突
用户注册或消息去重场景中，业务代码先 `SELECT` 检查某条记录是否存在，不存在则 `INSERT`。单线程下没问题，但高并发下两个请求同时检查到"不存在"，随后都执行 INSERT，第二个请求报 `ERROR 1062 (23000): Duplicate entry 'CODE_NEW' for key 'uk_code'`，唯一键冲突。

```sql
-- 两个并发事务都先查询 uk_code 不存在，然后都执行 INSERT，导致唯一键冲突
-- 会话A:
BEGIN;
SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在

-- 会话B:
BEGIN;
SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在

-- 会话A:
INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);  -- 成功
COMMIT;

-- 会话B:
INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);
-- ❌ ERROR 1062 (23000): Duplicate entry 'CODE_NEW' for key 'uk_code'
```

这是经典的 **TOCTOU（Time-Of-Check-Time-Of-Use）竞态**：检查时刻（SELECT）和使用时刻（INSERT）之间存在时间窗口，检查结果在窗口内已过期但事务仍基于旧结果操作。根本原因是 SELECT 和 INSERT 不是原子操作。

::: warning 真实场景
"先查后插"是应用层最常见的并发模式：用户注册查重、消息幂等去重、点赞计数初始化。只要并发量上来，就会偶发 1062 冲突。很多团队靠捕获异常重试来"擦屁股"，但重试本身仍是 SELECT+INSERT，竞态依然存在。正确的做法是用单条原子语句消除竞态窗口。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 先 SELECT 检查再 INSERT（TOCTOU 竞态条件）
-- 两个并发事务都先查询 uk_code 不存在，然后都执行 INSERT，导致唯一键冲突
--
-- TOCTOU 竞态复现（需两个会话）：
--
--   会话A:
--     BEGIN;
--     SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在
--
--   会话B:
--     BEGIN;
--     SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';  -- 0，不存在
--
--   会话A:
--     INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);  -- 成功
--     COMMIT;
--
--   会话B:
--     INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);
--     -- ❌ ERROR 1062 (23000): Duplicate entry 'CODE_NEW' for key 'uk_code'
--     -- 唯一键冲突！SELECT 和 INSERT 之间有时间窗口，并发下不可靠

-- 步骤1: 先查询检查是否存在（TOCTOU 的 Check 阶段）
SELECT COUNT(*) AS exists_flag FROM t_unique_test WHERE uk_code = 'CODE_NEW';

-- 步骤2: 若 exists_flag=0 则插入（TOCTOU 的 Use 阶段，存在竞态窗口）
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE_NEW', 1, NOW());
```

### EXPLAIN 结果

```
-- 步骤1: EXPLAIN SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';
+----+-------------+---------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table         | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+---------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | t_unique_test | NULL       | const | uk_code       | uk_code | 130     | const |    1 |   100.00 | Using index |
+----+-------------+---------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+

-- 步骤2: EXPLAIN INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
| id | select_type | table         | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
|  1 | INSERT      | t_unique_test | NULL       | ALL  | NULL          | NULL | NULL    | NULL | NULL |     NULL | NULL  |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| SELECT type | `const` | 唯一索引等值查询，高效 |
| SELECT key | `uk_code` | 走唯一索引 |
| SELECT Extra | `Using index` | 覆盖索引，不回表 |

查询本身高效，**问题在于 SELECT 和 INSERT 是两条独立语句，存在竞态窗口**。

### 为什么慢

```
TOCTOU 竞态时间线：

时间线   会话A                              会话B
  T1     SELECT COUNT(*) WHERE              SELECT COUNT(*) WHERE
         uk_code='CODE_NEW' -> 0            uk_code='CODE_NEW' -> 0
         （Check: 不存在）                   （Check: 不存在）
  T2     INSERT ... VALUES ('CODE_NEW',1)
         -> 成功（Use: 插入）
  T3                                        INSERT ... VALUES ('CODE_NEW',1)
                                            -> ❌ ERROR 1062 (23000):
                                               Duplicate entry 'CODE_NEW'
                                               for key 'uk_code'
```

TOCTOU 原理：

- **Time-Of-Check（检查时刻）**：T1 时两个事务都查到 CODE_NEW 不存在
- **Time-Of-Use（使用时刻）**：T2/T3 时两个事务都尝试插入
- **竞态窗口**：T1 到 T3 之间，检查结果已过期（会话A 已插入），但会话B 仍基于旧结果操作
- **根本原因**：SELECT 和 INSERT 不是原子操作，中间有间隙可被其他事务插入

应用层捕获异常重试也治标不治本：

```python
# ❌ 仍有竞态：捕获 1062 后重试，但 SELECT+INSERT 仍非原子
try:
    count = db.query("SELECT COUNT(*) FROM t_unique_test WHERE uk_code='CODE_NEW'")
    if count == 0:
        db.execute("INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1)")
except DuplicateKeyError:
    # 冲突后重试，但重试仍是 SELECT+INSERT，竞态依然存在
    db.execute("UPDATE t_unique_test SET counter=counter+1 WHERE uk_code='CODE_NEW'")
```

::: tip 核心认知
任何"先查后插"的模式都有 TOCTOU 竞态。SELECT 和 INSERT 之间的时间窗口是并发 bug 的温床。用单条原子语句将检查与插入/更新合并，才能彻底消除竞态。
:::

## 优化方案

### good.sql

```sql
-- good.sql: INSERT ... ON DUPLICATE KEY UPDATE 原子解决并发冲突
-- 单条语句原子完成"不存在则插入，存在则更新"，无竞态窗口
-- 若 uk_code 已存在，触发 ON DUPLICATE KEY UPDATE 更新 counter，不报错

-- 原子 upsert：不存在则插入，存在则 counter+1
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE_NEW', 1, NOW())
ON DUPLICATE KEY UPDATE counter = counter + 1, updated_at = NOW();

-- 对于已存在的记录（如 CODE00001），同样原子更新计数
INSERT INTO t_unique_test (uk_code, counter, updated_at)
VALUES ('CODE00001', 1, NOW())
ON DUPLICATE KEY UPDATE counter = counter + 1, updated_at = NOW();
```

### 原理

`INSERT ... ON DUPLICATE KEY UPDATE` 是单条原子语句。InnoDB 执行流程：尝试 INSERT -> 检测唯一键冲突 -> 若冲突则改为 UPDATE（而非报错）。整个过程在行锁内完成，无竞态窗口。

```
原子 upsert 的并发执行时间线：

时间线   会话A                              会话B
  T1     INSERT ... ON DUPLICATE KEY         INSERT ... ON DUPLICATE KEY
         UPDATE ('CODE_NEW', 1)              UPDATE ('CODE_NEW', 1)
  T2     -> 尝试插入 CODE_NEW
         -> 唯一索引无冲突
         -> 插入成功，affected_rows=1
         -> 释放锁
  T3                                        -> 等待唯一索引锁（A 持有）
  T4                                        -> 获取锁
                                            -> 尝试插入 CODE_NEW
                                            -> 唯一索引冲突！
                                            -> 触发 ON DUPLICATE KEY UPDATE
                                            -> counter = counter + 1
                                            -> affected_rows=2（更新成功）
                                            -> 无报错！
```

- 会话A 插入成功（affected_rows=1）
- 会话B 检测到冲突，自动转为 UPDATE（affected_rows=2），不报错
- 两个并发请求都成功完成，无竞态、无重试

affected_rows 的含义：

| 场景 | affected_rows | 含义 |
|------|--------------|------|
| CODE_NEW 不存在（插入） | 1 | 新插入 1 行 |
| CODE00001 已存在（更新） | 2 | 更新了 1 行（MySQL 约定：insert 算 1，update 算 2） |
| 已存在但值未变 | 0 | 无实际变化 |

其他原子 upsert 方案对比：

| 方案 | 语法 | 特点 |
|------|------|------|
| ON DUPLICATE KEY UPDATE | MySQL 专属 | 存在则更新，最常用 |
| INSERT IGNORE | MySQL 专属 | 存在则忽略（不更新），适合幂等插入 |
| REPLACE INTO | MySQL 专属 | 存在则先 DELETE 再 INSERT（会变 id，慎用） |
| MERGE | SQL 标准 | Oracle/PostgreSQL 语法，MySQL 不支持 |

### 对比

| | bad.sql（SELECT+INSERT） | good.sql（ON DUPLICATE KEY） |
|---|---|---|
| 原子性 | 非原子（两步） | **原子（单语句）** |
| 竞态窗口 | 有（TOCTOU） | **无** |
| 唯一键冲突 | 报错 1062 | **不报错，自动更新** |
| 并发安全 | 否 | **是** |
| 应用层重试 | 需要 | **不需要** |
| 语句数 | 2（SELECT + INSERT） | **1** |
| 网络往返 | 2 次 | **1 次** |

<ExplainCompare
  :bad="{ type: 'const', key: 'uk_code', rows: '1', Extra: 'SELECT+INSERT 非原子，TOCTOU 竞态报 1062' }"
  :good="{ type: 'INSERT', key: 'uk_code', rows: '1', Extra: 'ON DUPLICATE KEY 原子 upsert，无竞态无报错' }"
  improvement="单条原子语句消除竞态窗口，并发安全，无需应用层重试"
/>

## 避坑指南

::: warning 注意事项

1. **永远不要 SELECT 检查再 INSERT**：任何"先查后插"的模式都有 TOCTOU 竞态，用原子 upsert 替代。

2. **ON DUPLICATE KEY 需要唯一索引**：必须有 UNIQUE KEY 或 PRIMARY KEY 才能触发，否则等同于普通 INSERT。

3. **避免 REPLACE INTO**：REPLACE 会先 DELETE 再 INSERT，导致自增 id 变化、外键级联问题，优先用 ON DUPLICATE KEY。

4. **INSERT IGNORE 适合幂等插入**：只需保证记录存在、不需更新时用 INSERT IGNORE（如日志去重）。

5. **注意 affected_rows 语义**：插入返回 1，更新返回 2，未变返回 0，应用层据此判断。

6. **高并发计数器**：ON DUPLICATE KEY UPDATE counter=counter+1 是高并发计数器的标准写法。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| ON DUPLICATE KEY UPDATE | ✅ 支持 | ✅ 支持 |
| affected_rows 语义 | insert=1, update=2 | 一致（insert=1, update=2） |
| 唯一键冲突错误码 | 1062 | 1062（一致） |
| INSERT 唯一键检查优化 | 标准 | 减少不必要的 GAP 锁 |

::: tip 8.0 优化
8.0 对 INSERT 的唯一键检查有优化，减少了不必要的 GAP 锁，在高并发插入场景下锁冲突更少。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 69-unique-index-concurrent-insert

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 69-unique-index-concurrent-insert --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 69-unique-index-concurrent-insert --no-seed
```
