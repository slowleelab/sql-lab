# EXPLAIN 参考结果 - bad.sql (先查后改，非原子)

## MySQL 8.0（1000 个商品）

```
-- EXPLAIN SELECT
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------+
| id | select_type | table   | partitions | type  | possible_keys | key         | key_len | ref   | rows | filtered | Extra |
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_stock | NULL       | const | uk_product    | uk_product  | 4       | const |    1 |   100.00 | NULL  |
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------+
```

## 关键问题

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 主键/唯一索引等值查询，最高效 |
| key | `uk_product` | 走了唯一索引 |
| rows | 1 | 精确命中 1 行 |
| Extra | `NULL` | 无额外操作 |

## 为什么慢/为什么错

这条 SELECT 本身执行极快（const 级别），**问题不在查询性能，而在并发正确性**：

### 先查后改的超卖场景

```
时间线  请求A                    请求B
  T1    SELECT stock -> 1
  T2                             SELECT stock -> 1
  T3    判断 stock>0 ✓
  T4                             判断 stock>0 ✓
  T5    UPDATE stock=stock-1 -> 0
  T6                             UPDATE stock=stock-1 -> -1  ❌ 超卖！
```

1. **非原子操作**：SELECT 查询和 UPDATE 更新是两个独立的事务步骤
2. **时间窗口**：T1~T5 之间，请求 A 读到的 stock=1 已经过时（请求 B 也读到 1）
3. **TOCTOU 问题**：Time-Of-Check（检查 stock>0）到 Time-Of-Use（执行扣减）之间存在间隙
4. **并发超卖**：多个请求同时读到 stock>0，都执行扣减，库存变为负数

### 完整的先查后改代码（错误示例）

```python
# ❌ 错误：先查后改，并发下超卖
stock = db.query("SELECT stock FROM t_stock WHERE product_id=1")  # bad.sql
if stock > 0:
    db.execute("UPDATE t_stock SET stock=stock-1 WHERE product_id=1")
    # 并发请求都通过了 if 判断，都执行了扣减 -> 超卖
```

### 为什么用悲观锁也不理想

```sql
-- 悲观锁方案：SELECT ... FOR UPDATE 锁行，再更新
BEGIN;
SELECT stock FROM t_stock WHERE product_id=1 FOR UPDATE;  -- 加行锁
-- 应用层判断 stock > 0
UPDATE t_stock SET stock=stock-1 WHERE product_id=1;
COMMIT;
```

悲观锁虽能防超卖，但：
- 行锁持有时间长（整个事务期间），高并发下大量请求排队等待
- 事务粒度大，死锁风险高
- 吞吐量受限，不适合秒杀场景

## MySQL 5.7 差异

5.7 行为一致，const 查询同样高效。超卖问题与版本无关，是并发编程的经典问题。
