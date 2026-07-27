# EXPLAIN 参考结果 - good.sql (乐观锁 CAS 原子更新)

## MySQL 8.0（5 万商品库存数据）

```
-- 步骤1: EXPLAIN SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------+
```

```
-- 步骤2: EXPLAIN UPDATE t_stock_lock SET stock=stock-1, version=version+1
--        WHERE product_id=1 AND version=0 AND stock>0;
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
| id | select_type | table        | partitions | type  | possible_keys | key        | key_len | ref   | rows | filtered | Extra       |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_stock_lock | NULL       | const | uk_product    | uk_product | 8       | const |    1 |   100.00 | Using where |
+----+-------------+--------------+------------+-------+---------------+------------+---------+-------+------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 唯一索引等值定位 |
| key | `uk_product` | 走唯一索引 |
| rows | 1 | 精确命中 1 行 |
| Extra | `Using where` | **version=0 AND stock>0 在行锁内原子判断** |

## 为什么吞吐更高

### 乐观锁的执行时间线

```
时间线   事务A                          事务B                          事务C
  T1     SELECT stock,version;          -- 无锁读（快照），version=0
  T2                                    SELECT stock,version;          -- 无锁读，version=0
  T3                                                                   SELECT stock,version;  -- 无锁读
  T4     UPDATE ... WHERE version=0;    -- 加行锁，CAS 成功
         -> stock-1, version=1          -> affected_rows=1
         -> 释放锁
  T5                                    UPDATE ... WHERE version=0;    -- 加行锁，version 已变
                                        -> affected_rows=0（冲突！）
  T6                                    -- 重试：SELECT（读到 version=1）
  T7                                    UPDATE ... WHERE version=1;    -- CAS 成功
```

- 步骤1的 SELECT **不加锁**（快照读），多个事务可并行读取
- 仅步骤2的 UPDATE 瞬间加行锁，持锁时间极短（微秒级）
- 冲突时 affected_rows=0，应用层重试（重新读 version 再更新）

### 乐观锁 vs 悲观锁对比

| 维度 | 悲观锁（bad） | 乐观锁（good） |
|------|-------------|---------------|
| 读操作 | FOR UPDATE 加锁 | **无锁快照读** |
| 行锁持有 | 整个事务期间 | 仅 UPDATE 瞬间 |
| 并发读 | 串行 | **并行** |
| 冲突处理 | 等待（排队） | 重试（CAS） |
| 死锁风险 | 较高 | 极低 |
| 适合场景 | 写冲突频繁 | 读多写少/冲突少 |

### 乐观锁的应用层重试逻辑

```python
# ✅ 乐观锁扣减（含重试）
for attempt in range(max_retry=3):
    row = db.query("SELECT stock, version FROM t_stock_lock WHERE product_id=1")
    if row.stock <= 0:
        return "库存不足"
    affected = db.execute("""
        UPDATE t_stock_lock
        SET stock = stock - 1, version = version + 1, updated_at = NOW()
        WHERE product_id = 1 AND version = %s AND stock > 0
    """, (row.version,))
    if affected == 1:
        return "扣减成功"
    # affected=0 表示版本已变，重试
# 重试次数用尽
return "并发冲突，请重试"
```

## 量化对比

| 指标 | 悲观锁 | 乐观锁（冲突率低） | 乐观锁（冲突率高） |
|------|--------|------------------|------------------|
| 行锁持有时间 | 长（整个事务） | 极短（UPDATE瞬间） | 极短+重试 |
| 并发吞吐 | 低（串行） | **高** | 中（重试开销） |
| 死锁风险 | 中 | **极低** | 极低 |
| 实现复杂度 | 简单 | 需重试逻辑 | 需重试逻辑 |

## 避坑指南

1. **冲突率高时用悲观锁**：乐观锁重试次数过多反而比悲观锁慢，写冲突频繁的场景应选悲观锁
2. **version 字段必须有索引**：`WHERE version=N` 需要走索引定位，否则 UPDATE 退化为扫描
3. **重试次数要限制**：乐观锁重试应有上限（如 3 次），避免无限重试耗尽资源
4. **stock>0 条件不可省**：即使 version 匹配，也要检查 stock>0 防止扣成负数
5. **悲观锁要短事务**：若用悲观锁，尽快 COMMIT 释放锁，不要在锁内做耗时操作
6. **混合策略**：热点商品用悲观锁（冲突高），普通商品用乐观锁（冲突低）

## 5.7 vs 8.0 差异

- 乐观锁 CAS 机制在 5.7 和 8.0 一致，均依赖 `affected_rows` 判断冲突
- 8.0 可用 `data_locks` 验证乐观锁 UPDATE 瞬间的短暂行锁
- 8.0 的 SKIP LOCKED 可用于悲观锁的队列场景优化（跳过被锁行）
