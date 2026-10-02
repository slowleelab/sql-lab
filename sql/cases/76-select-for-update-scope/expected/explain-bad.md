# EXPLAIN 参考结果 - bad.sql (无索引 FOR UPDATE，锁升级为表锁)

## MySQL 8.0（10 万行商品数据，category 无索引）

```
-- EXPLAIN SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
| id | select_type | table      | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra |
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
|  1 | SIMPLE      | t_product  | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 100155 |    20.00 | NULL  |
+----+-------------+------------+------------+------+---------------+------+---------+------+--------+----------+-------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ALL` | **全表扫描**，无索引可用 |
| possible_keys | `NULL` | 没有任何候选索引 |
| key | `NULL` | 未使用索引 |
| rows | ~100,155 | 扫描全部 10 万行 |
| filtered | 20.00 | 约 20% 行匹配（5 个分类各约 2 万） |

## 为什么锁全表

### 无索引时的加锁行为

- FOR UPDATE 需要**对所有扫描到的行加排他锁（X 锁）**
- category 无索引 -> 全表扫描 -> **每行都加 X 锁**
- 虽然只有 `category='电子'` 的行匹配，但扫描过程中所有行都被锁
- 效果等同于**表锁**：其他事务对该表任意行的 UPDATE/DELETE/INSERT 均被阻塞

```
时间线   会话A（无索引 FOR UPDATE）          会话B（任意行更新被阻塞）
  T1     BEGIN;
  T2     SELECT ... WHERE category='电子'
            FOR UPDATE;   -- 全表扫描，锁所有行
  T3                                        BEGIN;
  T4                                        UPDATE t_product SET stock=stock-1 WHERE id=1;
                                            -- ❌ 被阻塞！id=1 即使不是电子产品也被锁
  T5     （未提交）
  T6                                        超时：ERROR 1205 Lock wait timeout exceeded
```

### 锁范围验证（8.0）

```sql
SELECT lock_type, lock_mode, COUNT(*) AS lock_count
FROM performance_schema.data_locks
WHERE object_name = 't_product'
GROUP BY lock_type, lock_mode;
-- 结果：RECORD 类型锁的数量 = 全表行数（每行都被锁）
```

## 实际影响

| 操作 | 是否被阻塞 | 原因 |
|------|-----------|------|
| UPDATE 任意行 | **是** | 全表行锁 |
| DELETE 任意行 | **是** | 全表行锁 |
| INSERT 新行 | **是** | 插入意向锁与行锁冲突 |
| 其他事务 SELECT（无锁） | 否 | 普通读不加锁 |

## 5.7 vs 8.0 差异

- 无索引导致锁全表的行为在 5.7 和 8.0 一致
- 5.7 中 RR 下还可能叠加大量间隙锁，锁范围更大
- 8.0 可通过 `data_locks` 精确统计被锁行数
