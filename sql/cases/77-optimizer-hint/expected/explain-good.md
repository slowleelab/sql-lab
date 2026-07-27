# EXPLAIN 参考结果 - good.sql (USE INDEX 强制使用 idx_user_created)

## MySQL 8.0（实测 8.0.46，100 万行订单数据）

```
-- EXPLAIN SELECT * FROM t_order USE INDEX (idx_user_created) WHERE user_id = 100 AND status = 1 ORDER BY created_at DESC LIMIT 10;
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------+------+----------+-------------+
| id | select_type | table   | partitions | type | possible_keys            | key              | key_len | ref   | rows | filtered | Extra       |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | t_order | NULL       | ref  | idx_user_created         | idx_user_created | 8       | const |   10 |    10.00 | Using where |
+----+-------------+---------+------------+------+--------------------------+------------------+---------+-------+------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 索引等值查找 |
| key | `idx_user_created` | 强制使用正确的索引 |
| rows | ~10 | user_id=100 仅约 10 行 |
| filtered | 10.00 | 回表后过滤 status=1 |
| Extra | `Using where` | 索引有序，无需 filesort |

## 为什么快

### 执行流程

1. 通过 `idx_user_created` 索引定位 `user_id=100` 的约 10 行索引记录
2. 索引按 `(user_id, created_at)` 有序，直接反向读取最后 10 行（DESC）
3. 每行回表查询完整行数据，过滤 `status = 1`
4. 返回结果

**核心优势**：
- 只扫描 10 行索引（vs bad 的 35 万行）
- 索引有序，无需 filesort（vs bad 的 filesort）
- 只回表 10 次（vs bad 的 35 万次）

### USE INDEX vs FORCE INDEX vs IGNORE INDEX

| Hint | 作用 | 使用场景 |
|------|------|---------|
| `USE INDEX (idx)` | 建议优化器使用指定索引，优化器仍可选其他索引 | 优化器通常选对，但想确保 |
| `FORCE INDEX (idx)` | 强制优化器使用指定索引，不考虑其他索引 | 优化器明确选错，需强制纠正 |
| `IGNORE INDEX (idx)` | 禁止优化器使用指定索引 | 某个索引导致性能问题，需禁用 |

```sql
-- USE INDEX: 建议但不强制
SELECT * FROM t_order USE INDEX (idx_user_created) WHERE ...;

-- FORCE INDEX: 强制使用
SELECT * FROM t_order FORCE INDEX (idx_user_created) WHERE ...;

-- IGNORE INDEX: 禁止使用
SELECT * FROM t_order IGNORE INDEX (idx_status) WHERE ...;
```

### 使用 Hint 的注意事项

1. **不要过度使用**：Hint 是"硬编码"，数据分布变化后可能不再最优
2. **优先更新统计信息**：`ANALYZE TABLE t_order` 让优化器基于准确统计做决策
3. **考虑索引优化**：如果经常需要 Hint，说明索引设计可能不合理
4. **监控执行计划**：使用 Hint 后定期检查执行计划，确保仍然最优

```sql
-- 优先尝试：更新统计信息
ANALYZE TABLE t_order;

-- 如果统计信息准确后优化器仍选错，再考虑 Hint
```

## 量化对比

| 指标 | bad.sql（误选 idx_status） | good.sql（USE INDEX） |
|------|---------------------------|----------------------|
| key | idx_status | idx_user_created |
| rows | ~349,872 | **~10** |
| Extra | Using filesort | **Using where** |
| 回表次数 | ~349,872 | **~10** |
| 耗时 | ~850 ms | **~0.5 ms** |
| 提升 | - | **1700x** |

## 5.7 vs 8.0 差异

- USE INDEX / FORCE INDEX / IGNORE INDEX 在两个版本中语法一致
- 8.0 的代价模型略有改进，但 Hint 仍是纠正优化器错误的有效手段
- 8.0 支持 `EXPLAIN ANALYZE` 可对比 Hint 前后的实际执行代价

::: tip 优化器 Hint 使用原则
Hint 是"最后的手段"，不是"首选方案"。正确的优化顺序：
1. 更新统计信息（ANALYZE TABLE）
2. 优化索引设计（添加/修改索引）
3. 使用 Hint 强制索引（临时方案）
4. 长期方案：修复统计信息或索引设计，移除 Hint

Hint 会让 SQL 与特定索引绑定，索引重建或改名后 Hint 可能失效，需同步维护。
:::
