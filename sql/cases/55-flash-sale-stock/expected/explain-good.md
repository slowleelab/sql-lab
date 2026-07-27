# EXPLAIN 参考结果 - good.sql (原子条件更新，乐观锁)

## MySQL 8.0（1000 个商品）

```
-- EXPLAIN UPDATE
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------------+
| id | select_type | table   | partitions | type  | possible_keys | key         | key_len | ref   | rows | filtered | Extra       |
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------------+
|  1 | UPDATE      | t_stock | NULL       | const | uk_product    | uk_product  | 4       | const |    1 |   100.00 | Using where |
+----+-------------+---------+------------+-------+---------------+-------------+---------+-------+------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `const` | 唯一索引等值定位 |
| key | `uk_product` | 走唯一索引精确命中 |
| rows | 1 | 精确命中 1 行 |
| Extra | `Using where` | **WHERE stock > 0 条件在行锁内原子判断** |

## 为什么快/为什么对

单条 `UPDATE ... WHERE product_id=1 AND stock > 0` 利用 InnoDB 行锁保证原子性：

### 原子条件更新的防超卖原理

```
时间线  请求A                            请求B
  T1    UPDATE ... WHERE stock>0
        -> 获取 product_id=1 的行锁
        -> 判断 stock(=1) > 0 ✓
        -> stock = 1-1 = 0
        -> 释放行锁
        -> affected_rows = 1 (成功)
  T2                                     UPDATE ... WHERE stock>0
                                         -> 等待行锁（A 持有）
  T3                                     -> 获取行锁
                                         -> 判断 stock(=0) > 0 ✗
                                         -> 不执行扣减
                                         -> affected_rows = 0 (库存不足)
```

1. **判断与扣减原子化**：`WHERE stock > 0` 和 `SET stock=stock-1` 在同一条语句内，InnoDB 行锁保证不被打断
2. **无需显式加锁**：UPDATE 自动获取行锁，不需要 SELECT ... FOR UPDATE
3. **affected_rows 反馈结果**：返回 1 表示扣减成功，返回 0 表示库存不足，应用层据此判断
4. **行锁持有极短**：单条 UPDATE 的行锁只在语句执行期间持有，事务自动提交后释放
5. **高吞吐**：行锁持有时间极短（微秒级），并发请求快速轮流执行

### 应用层代码（正确示例）

```python
# ✅ 正确：原子条件更新，防超卖
affected = db.execute("""
    UPDATE t_stock
    SET stock = stock - 1, version = version + 1, updated_at = NOW()
    WHERE product_id = 1 AND stock > 0
""")
if affected == 1:
    # 扣减成功，创建订单
    create_order(user_id, product_id)
else:
    # 库存不足，秒杀失败
    return "已抢完"
```

### version 字段的作用

`version = version + 1` 是乐观锁的版本号机制，可用于：
- 检测并发冲突（CAS 模式）：`WHERE product_id=1 AND version=旧版本号`
- 幂等性校验：记录更新次数，防止重复扣减
- 在 `stock > 0` 的基础上提供额外的并发安全保障

## 量化对比

| 指标 | bad (先查后改) | good (原子更新) | 提升 |
|------|---------------|-----------------|------|
| 原子性 | 非原子（两步） | **原子（单语句）** | 消除超卖 |
| 并发正确性 | 超卖 | **零超卖** | 正确性保证 |
| 行锁持有 | 无（SELECT 无锁） | 极短（UPDATE 期间） | 高吞吐 |
| 请求排队 | 无（但超卖） | 短暂（行锁轮流） | 可控 |
| 事务复杂度 | 需显式事务 | **单语句自动提交** | 简化 |

## 5.7 vs 8.0 差异

- 执行计划结构一致，原子条件更新方案在两个版本上都有效
- InnoDB 行锁机制在 5.7 和 8.0 中行为一致
- 8.0 的 SKIP LOCKED 语法可用于进一步优化排队场景（跳过被锁行）

## 避坑指南

1. **永远不要先查后改**：任何"先 SELECT 判断再 UPDATE"的模式在并发下都有 TOCTOU 风险
2. **WHERE 条件包含库存检查**：`WHERE stock > 0` 是防超卖的核心，确保扣减和判断在同一语句
3. **用 affected_rows 判断结果**：不要假设 UPDATE 一定成功，检查返回的受影响行数
4. **考虑 Redis 预扣减**：秒杀场景可在 Redis 中预扣减库存（DECR 原子操作），成功再异步落库
5. **注意死锁风险**：如果一次扣减多个商品库存，按固定顺序加锁（如按 product_id 排序），避免死锁
6. **库存预热**：秒杀开始前将库存加载到 Redis，数据库只做最终一致性落库
7. **8.0 SKIP LOCKED**：高并发跳过被锁行，`SELECT ... FOR UPDATE SKIP LOCKED` 适合任务队列场景
