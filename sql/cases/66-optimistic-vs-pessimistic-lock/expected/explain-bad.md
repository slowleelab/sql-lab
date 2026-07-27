# EXPLAIN 参考结果 - bad.sql (悲观锁 SELECT FOR UPDATE)

## MySQL 8.0（5 万商品库存数据）

```
-- EXPLAIN SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1 FOR UPDATE;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
```

```
-- EXPLAIN UPDATE t_stock_lock SET stock=stock-1 WHERE product_id=1;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra       |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | Using where |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 唯一索引等值定位，查询本身高效 |
| key | `uk_product` | 走唯一索引 |
| rows | 1 | 精确命中 1 行 |

查询性能没问题，**问题在于悲观锁的持锁时间长、并发吞吐低**。

## 为什么吞吐受限

### 悲观锁的执行时间线

```
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

### 悲观锁的锁持有分析（8.0）

```sql
SELECT lock_type, lock_mode, lock_data, lock_status
FROM performance_schema.data_locks
WHERE object_name = 't_stock_lock';
-- 在 BEGIN; SELECT ... FOR UPDATE; 后查询：
-- RECORD | X,REC_NOT_GAP | 1 | GRANTED   -- product_id=1 行锁，持锁直到 COMMIT
```

## 悲观锁适用与不适用场景

| 场景 | 是否适合悲观锁 |
|------|--------------|
| 冲突频繁（写多） | 适合（避免大量重试） |
| 冲突稀少（读多写少） | 不适合（持锁浪费） |
| 长事务 | 不适合（锁持有久） |
| 短事务 + 高并发同行 | 适合但吞吐有上限 |

## 5.7 vs 8.0 差异

- 悲观锁机制一致，SELECT FOR UPDATE 均加行锁直到 COMMIT
- 8.0 可用 `data_locks` 观察锁持有；5.7 用 `SHOW ENGINE INNODB STATUS`
