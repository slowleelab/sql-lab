# 秒杀场景库存扣减

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['秒杀', '库存扣减', '乐观锁', '防超卖', '行锁']" />

## 100 件库存卖了 130 单：先查后改的超卖事故
秒杀活动上线，100 件库存，结果卖出了 **130 单**--超卖 30 件，客诉爆炸。排查代码发现是经典的"先查后改"模式：

```sql
-- 步骤1: 先查库存
SELECT stock FROM t_stock WHERE product_id = 1;
-- 应用层判断 stock > 0
-- 步骤2: 再扣减
UPDATE t_stock SET stock = stock - 1 WHERE product_id = 1;
```

这条 SELECT 本身执行极快（const 级别），但问题不在性能，而在**并发正确性**--查询和更新是两个独立步骤，中间存在时间窗口，高并发下多个请求都读到 stock>0，都执行扣减，库存变成负数。

这就是 **"先查后改超卖"** 事故--TOCTOU（Time-Of-Check to Time-Of-Use）问题，并发编程的经典陷阱。秒杀、抢券、抢票、限量预约，凡是"先查再改"的库存扣减场景都可能踩到。

::: warning 真实场景
秒杀、抢购、抢红包、限量预约、抢票--任何"库存有限、并发扣减"的场景，只要用"先 SELECT 判断再 UPDATE 扣减"的模式，高并发下必然超卖。这不是概率问题，而是必然的并发缺陷。
:::

## 问题分析

### bad.sql

```sql
-- 先查后改模式（非原子，并发下超卖）：
-- 步骤1: SELECT 查库存 -> 应用层判断 stock > 0
-- 步骤2: UPDATE SET stock=stock-1
-- 两个步骤之间存在时间窗口，并发请求都读到 stock>0 则都执行扣减 -> 超卖
-- bad.sql 展示步骤1的 SELECT（问题根源在查询与更新的非原子性）
SELECT stock FROM t_stock WHERE product_id = 1;
```

### EXPLAIN 结果

```
-- EXPLAIN SELECT
+----+---------+-------+---------------+---------+---------+-------+----------+-------+
| id | table   | type  | possible_keys | key     | key_len | ref   | rows  | filtered| Extra |
+----+---------+-------+---------------+---------+---------+-------+-------+----------+-------+
|  1 | t_stock | const | uk_product    | uk_product| 4      | const | 1     | 100.00  | NULL  |
+----+---------+-------+---------------+---------+---------+-------+-------+----------+-------+
```

这条 SELECT 本身执行极快（`type=const`，唯一索引等值查询，`rows=1`）。**问题不在查询性能，而在并发正确性。**

### 为什么错

先查后改的超卖场景：

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

完整的先查后改代码（错误示例）：

```python
# ❌ 错误：先查后改，并发下超卖
stock = db.query("SELECT stock FROM t_stock WHERE product_id=1")  # bad.sql
if stock > 0:
    db.execute("UPDATE t_stock SET stock=stock-1 WHERE product_id=1")
    # 并发请求都通过了 if 判断，都执行了扣减 -> 超卖
```

::: tip 为什么用悲观锁也不理想
悲观锁方案 `SELECT ... FOR UPDATE` 虽能防超卖，但行锁持有时间长（整个事务期间），高并发下大量请求排队等待；事务粒度大，死锁风险高；吞吐量受限，不适合秒杀场景。
:::

## 优化方案

### good.sql

```sql
-- 原子条件更新（乐观锁）：WHERE stock > 0 防超卖
-- 单条 UPDATE 利用 InnoDB 行锁保证原子性：判断 stock>0 和扣减在同一事务内完成
-- 返回 affected_rows=1 表示扣减成功，=0 表示库存不足（已被抢完）
-- version+1 用于乐观锁冲突检测（可选，stock>0 已足够防超卖）
UPDATE t_stock
SET stock = stock - 1,
    version = version + 1,
    updated_at = NOW()
WHERE product_id = 1 AND stock > 0;
```

### EXPLAIN 结果

```
-- EXPLAIN UPDATE
+----+---------+-------+---------------+---------+---------+-------+------+----------+-------------+
| id | table   | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra       |
+----+---------+-------+---------------+---------+---------+-------+------+----------+-------------+
|  1 | t_stock | const | uk_product    | uk_product| 4      | const | 1   | 100.00   | Using where |
+----+---------+-------+---------------+---------+---------+-------+------+----------+-------------+
```

### 原理

单条 `UPDATE ... WHERE product_id=1 AND stock > 0` 利用 InnoDB 行锁保证原子性：

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

应用层代码（正确示例）：

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

::: tip version 字段的作用
`version = version + 1` 是乐观锁的版本号机制，可用于：检测并发冲突（CAS 模式）`WHERE product_id=1 AND version=旧版本号`；幂等性校验，记录更新次数防止重复扣减；在 `stock > 0` 的基础上提供额外的并发安全保障。
:::

<ExplainCompare
  :bad="{ type: 'const', key: 'uk_product', rows: '1', Extra: 'SELECT 无锁，先查后改非原子，并发超卖' }"
  :good="{ type: 'const', key: 'uk_product', rows: '1', Extra: 'UPDATE 行锁内原子判断 stock>0，affected_rows 反馈结果' }"
  improvement="从非原子两步操作变为原子单语句，消除超卖，行锁持有极短保证高吞吐"
/>

## 量化对比

| 指标 | bad (先查后改) | good (原子更新) | 提升 |
|------|---------------|-----------------|------|
| 原子性 | 非原子（两步） | **原子（单语句）** | 消除超卖 |
| 并发正确性 | 超卖 | **零超卖** | 正确性保证 |
| 行锁持有 | 无（SELECT 无锁） | 极短（UPDATE 期间） | 高吞吐 |
| 请求排队 | 无（但超卖） | 短暂（行锁轮流） | 可控 |
| 事务复杂度 | 需显式事务 | **单语句自动提交** | 简化 |

## 避坑指南

::: warning 注意事项

1. **永远不要先查后改**：任何"先 SELECT 判断再 UPDATE"的模式在并发下都有 TOCTOU 风险。

2. **WHERE 条件包含库存检查**：`WHERE stock > 0` 是防超卖的核心，确保扣减和判断在同一语句。

3. **用 affected_rows 判断结果**：不要假设 UPDATE 一定成功，检查返回的受影响行数。

4. **考虑 Redis 预扣减**：秒杀场景可在 Redis 中预扣减库存（DECR 原子操作），成功再异步落库。

5. **注意死锁风险**：如果一次扣减多个商品库存，按固定顺序加锁（如按 product_id 排序），避免死锁。

6. **库存预热**：秒杀开始前将库存加载到 Redis，数据库只做最终一致性落库。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 原子条件更新方案 | ✅ 有效 | ✅ 有效 |
| InnoDB 行锁机制 | 一致 | 一致 |
| SKIP LOCKED 语法 | ❌ 不支持 | ✅ 支持 |
| 防超卖效果 | 零超卖 | 零超卖 |

::: tip 8.0 SKIP LOCKED
执行计划结构在两个版本上一致，原子条件更新方案都有效，InnoDB 行锁机制行为一致。

8.0 额外支持 `SKIP LOCKED` 语法，可用于进一步优化排队场景：

```sql
-- 8.0: 跳过被锁行，适合任务队列场景
SELECT * FROM t_stock
WHERE product_id IN (1, 2, 3) AND stock > 0
FOR UPDATE SKIP LOCKED;
```

被锁的行直接跳过，不等待，适合"抢不到就换一个"的秒杀变体场景。5.7 无此语法，只能等待行锁释放。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 55-flash-sale-stock

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 55-flash-sale-stock --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 55-flash-sale-stock --no-seed
```
