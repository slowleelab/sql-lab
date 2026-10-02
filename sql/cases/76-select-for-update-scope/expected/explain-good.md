# EXPLAIN 参考结果 - good.sql (加索引后 FOR UPDATE 只锁匹配行)

## MySQL 8.0（执行 setup-good.sql 加 idx_category 后）

```
-- EXPLAIN SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
+----+-------------+------------+------------+------+---------------+--------------+---------+-------+--------+----------+-------+
| id | select_type | table      | partitions | type | possible_keys | key          | key_len | ref   | rows   | filtered | Extra |
+----+-------------+------------+------------+------+---------------+--------------+---------+-------+--------+----------+-------+
|  1 | SIMPLE      | t_product  | NULL       | ref  | idx_category  | idx_category | 82      | const | 20031  |   100.00 | NULL  |
+----+-------------+------------+------------+------+---------------+--------------+---------+-------+--------+----------+-------+
```

## 关键改进

| 字段 | bad.sql | good.sql | 分析 |
|------|---------|----------|------|
| type | `ALL` | `ref` | 从全表扫描变为索引等值查找 |
| possible_keys | `NULL` | `idx_category` | 有了候选索引 |
| key | `NULL` | `idx_category` | **使用了新建的索引** |
| rows | ~100,155 | ~20,031 | 只扫描匹配行（约 2 万） |
| filtered | 20.00 | 100.00 | 索引精确匹配，无需二次过滤 |
| 锁范围 | 全表（10 万行） | **仅匹配行（约 2 万行）** | 锁范围缩小 80% |

## 为什么只锁匹配行

### 有索引时的加锁行为

- FOR UPDATE 通过 `idx_category` 索引定位到 `category='电子'` 的行
- 只对**实际匹配的行加 X 锁**（索引定位到的记录）
- 其他分类的行不被扫描、不加锁，可正常更新

```
时间线   会话A（有索引 FOR UPDATE）          会话B（非电子行更新成功）
  T1     BEGIN;
  T2     SELECT ... WHERE category='电子'
            FOR UPDATE;   -- 走索引，只锁电子产品
  T3                                        BEGIN;
  T4                                        UPDATE t_product SET stock=stock-1
                                            WHERE id = 1 AND category <> '电子';
                                            -- ✅ 不被阻塞（非电子行未加锁）
```

### 锁范围验证（8.0）

```sql
SELECT lock_type, lock_mode, COUNT(*) AS lock_count
FROM performance_schema.data_locks
WHERE object_name = 't_product'
GROUP BY lock_type, lock_mode;
-- 结果：RECORD 类型锁的数量 ≈ 2 万（仅电子产品行）
-- 对比 bad.sql 的 10 万行，锁范围大幅缩小
```

## 进一步优化：精确主键加锁

如果业务允许，用主键精确加锁只锁单行，锁范围最小：

```sql
-- 只锁 id=100 这一行（记录锁，影响最小）
SELECT * FROM t_product WHERE id = 100 FOR UPDATE;
```

```
-- EXPLAIN SELECT * FROM t_product WHERE id = 100 FOR UPDATE;
+----+-------------+------------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
| id | select_type | table      | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra |
+----+-------------+------------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_product  | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+------------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
-- rows=1，只锁 1 行，并发性能最佳
```

## 量化对比

| 指标 | bad.sql（无索引） | good.sql（有索引） | 主键精确 |
|------|------------------|-------------------|---------|
| type | ALL | ref | const |
| 扫描行数 | ~100,155 | ~20,031 | 1 |
| 锁定行数 | 全表 | ~20,031 | 1 |
| 并发更新 | 全部阻塞 | 仅电子行阻塞 | 仅 1 行阻塞 |
| 锁等待概率 | 极高 | 中 | 极低 |

## 避坑指南

1. **FOR UPDATE 的 WHERE 必须走索引**：无索引 = 表锁，这是最常见的锁性能陷阱
2. **优先主键加锁**：业务允许时用 `WHERE id=N FOR UPDATE`，只锁单行
3. **区分度高才加索引**：category 只有 5 个值（区分度低），索引效果有限；高区分度字段加索引收益更大
4. **RR 下普通索引还会加间隙锁**：即使有索引，RR 下普通索引等值/范围仍可能加 next-key lock，考虑 RC
5. **缩短持锁时间**：FOR UPDATE 后立即做业务操作并 COMMIT，不要在锁内做耗时操作

## 5.7 vs 8.0 差异

- 有索引只锁匹配行的行为在 5.7 和 8.0 一致
- RR 下普通索引等值会加 next-key lock（含间隙），RC 下只加记录锁
- 8.0 的 `data_locks` 可直接验证锁行数
