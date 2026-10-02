# EXPLAIN 参考结果 - good.sql (INSERT ON DUPLICATE KEY UPDATE 原子 upsert)

## MySQL 8.0（10 万行唯一编码数据）

```
-- EXPLAIN INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1)
--           ON DUPLICATE KEY UPDATE counter = counter + 1;
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
| id | select_type | table         | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
|  1 | INSERT      | t_unique_test | NULL       | ALL  | NULL          | NULL | NULL    | NULL | NULL |     NULL | NULL  |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
```

```
-- 对于已存在记录的 upsert（CODE00001 已存在）
-- 执行后 affected_rows 含义：
--   1: 新插入一行（CODE_NEW 不存在）
--   2: 更新了已存在的行（CODE00001 存在，触发 ON DUPLICATE KEY UPDATE）
--   0: 已存在但值未变化
SELECT uk_code, counter FROM t_unique_test WHERE uk_code IN ('CODE_NEW', 'CODE00001');
```

## 关键改进

| 维度 | bad.sql（SELECT+INSERT） | good.sql（ON DUPLICATE KEY） |
|------|------------------------|----------------------------|
| 原子性 | 非原子（两步） | **原子（单语句）** |
| 竞态窗口 | 有（TOCTOU） | **无** |
| 唯一键冲突 | 报错 1062 | **不报错，自动更新** |
| 并发安全 | 否 | **是** |
| 应用层重试 | 需要 | **不需要** |

## 为什么并发安全

### 原子 upsert 机制

- `INSERT ... ON DUPLICATE KEY UPDATE` 是单条原子语句
- InnoDB 执行流程：尝试 INSERT -> 检测唯一键冲突 -> 若冲突则改为 UPDATE（而非报错）
- 整个过程在行锁内完成，无竞态窗口

### 并发执行时间线

```
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

### affected_rows 的含义

| 场景 | affected_rows | 含义 |
|------|--------------|------|
| CODE_NEW 不存在（插入） | 1 | 新插入 1 行 |
| CODE00001 已存在（更新） | 2 | 更新了 1 行（MySQL 约定：insert 算 1，update 算 2） |
| 已存在但值未变 | 0 | 无实际变化 |

### 应用层代码（正确示例）

```python
# ✅ 原子 upsert，并发安全，无需重试
affected = db.execute("""
    INSERT INTO t_unique_test (uk_code, counter, updated_at)
    VALUES (%s, 1, NOW())
    ON DUPLICATE KEY UPDATE counter = counter + 1, updated_at = NOW()
""", (code,))

if affected == 1:
    print("新记录已插入")
elif affected == 2:
    print("已存在，计数器已更新")
else:
    print("已存在，值未变化")
```

### 其他原子 upsert 方案对比

| 方案 | 语法 | 特点 |
|------|------|------|
| ON DUPLICATE KEY UPDATE | MySQL 专属 | 存在则更新，最常用 |
| INSERT IGNORE | MySQL 专属 | 存在则忽略（不更新），适合幂等插入 |
| REPLACE INTO | MySQL 专属 | 存在则先 DELETE 再 INSERT（会变 id，慎用） |
| MERGE | SQL 标准 | Oracle/PostgreSQL 语法，MySQL 不支持 |

```sql
-- 方案对比：
-- 1. ON DUPLICATE KEY UPDATE（推荐）：存在则更新 counter
INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE1', 1)
ON DUPLICATE KEY UPDATE counter = counter + 1;

-- 2. INSERT IGNORE：存在则忽略，不更新（适合幂等去重）
INSERT IGNORE INTO t_unique_test (uk_code, counter) VALUES ('CODE1', 1);

-- 3. REPLACE INTO：存在则删除重建（id 会变，外键风险，慎用）
REPLACE INTO t_unique_test (uk_code, counter) VALUES ('CODE1', 1);
```

## 量化对比

| 指标 | bad.sql | good.sql |
|------|---------|----------|
| 语句数 | 2（SELECT + INSERT） | **1** |
| 原子性 | 非原子 | **原子** |
| 并发冲突 | 1062 报错 | **无报错** |
| 应用层重试 | 需要 | **不需要** |
| 网络往返 | 2 次 | **1 次** |

## 避坑指南

1. **永远不要 SELECT 检查再 INSERT**：任何"先查后插"的模式都有 TOCTOU 竞态，用原子 upsert 替代
2. **ON DUPLICATE KEY 需要唯一索引**：必须有 UNIQUE KEY 或 PRIMARY KEY 才能触发，否则等同于普通 INSERT
3. **避免 REPLACE INTO**：REPLACE 会先 DELETE 再 INSERT，导致自增 id 变化、外键级联问题，优先用 ON DUPLICATE KEY
4. **INSERT IGNORE 适合幂等插入**：只需保证记录存在、不需更新时用 INSERT IGNORE（如日志去重）
5. **注意 affected_rows 语义**：插入返回 1，更新返回 2，未变返回 0，应用层据此判断
6. **高并发计数器**：ON DUPLICATE KEY UPDATE counter=counter+1 是高并发计数器的标准写法

## 5.7 vs 8.0 差异

- ON DUPLICATE KEY UPDATE 语法和行为在 5.7 和 8.0 一致
- 8.0 对 INSERT 的唯一键检查有优化（减少不必要的 GAP 锁）
- affected_rows 语义两个版本一致（insert=1, update=2）
