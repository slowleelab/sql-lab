# EXPLAIN 参考结果 - bad.sql (先 SELECT 再 INSERT，TOCTOU 竞态)

## MySQL 8.0（10 万行唯一编码数据）

```
-- 步骤1: EXPLAIN SELECT COUNT(*) FROM t_unique_test WHERE uk_code = 'CODE_NEW';
+----+-------------+---------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | select_type | table         | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+-------------+---------------+------------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | t_unique_test | NULL       | const | uk_code       | uk_code | 130     | const |    1 |   100.00 | Using index |
+----+-------------+---------------+------------+-------+---------------+---------+-------+-------+------+----------+-------------+
```

```
-- 步骤2: EXPLAIN INSERT INTO t_unique_test (uk_code, counter) VALUES ('CODE_NEW', 1);
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
| id | select_type | table         | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
|  1 | INSERT      | t_unique_test | NULL       | ALL  | NULL          | NULL | NULL    | NULL | NULL |     NULL | NULL  |
+----+-------------+---------------+------------+------+---------------+------+---------+------+------+----------+-------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| SELECT type | `const` | 唯一索引等值查询，高效 |
| SELECT key | `uk_code` | 走唯一索引 |
| SELECT Extra | `Using index` | 覆盖索引，不回表 |

查询本身高效，**问题在于 SELECT 和 INSERT 是两条独立语句，存在竞态窗口**。

## 为什么会冲突

### TOCTOU 竞态时间线

```
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

### TOCTOU 原理

- **Time-Of-Check（检查时刻）**：T1 时两个事务都查到 CODE_NEW 不存在
- **Time-Of-Use（使用时刻）**：T2/T3 时两个事务都尝试插入
- **竞态窗口**：T1 到 T3 之间，检查结果已过期（会话A 已插入），但会话B 仍基于旧结果操作
- **根本原因**：SELECT 和 INSERT 不是原子操作，中间有间隙可被其他事务插入

### 唯一键冲突错误

```
ERROR 1062 (23000): Duplicate entry 'CODE_NEW' for key 'uk_code'
```

- 错误码 1062：唯一键约束冲突
- InnoDB 在 INSERT 时检查唯一索引，发现已有相同值则报错回滚
- 应用层需捕获此错误并重试（重新 SELECT + INSERT），但仍有竞态

### 应用层错误处理（治标不治本）

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

## 5.7 vs 8.0 差异

- TOCTOU 竞态与版本无关，是并发编程的经典问题
- 唯一键冲突错误码 1062 在两个版本一致
