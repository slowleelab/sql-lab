# EXPLAIN 参考结果 - good.sql (索引辅助去重)

## MySQL 8.0（实测 8.0.46，20 万行数据）

```
+----+-------------+--------------+-------+----------------+----------------+---------+------+--------+----------+--------------------------+
| id | select_type | table        | type  | possible_keys  | key            | key_len | ref  | rows   | filtered | Extra                    |
+----+-------------+--------------+-------+----------------+----------------+---------+------+--------+----------+--------------------------+
|  1 | SIMPLE      | t_visit_log  | range | idx_user_visit | idx_user_visit | 9       | NULL |  66124 |   100.00 | Using index for group-by |
+----+-------------+--------------+-------+----------------+----------------+---------+------+--------+----------+--------------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | **`range`** | 索引范围扫描 |
| key | `idx_user_visit` | 使用联合索引 (user_id, visit_time) |
| rows | ~66,124 | 仅扫描满足条件的行 |
| Extra | **`Using index for group-by`** | **利用索引松散扫描去重，免临时表！** |

## 为什么更好

联合索引 `idx_user_visit (user_id, visit_time)` 的 B+ 树中，数据按 `user_id` 有序、同 user_id 内按 `visit_time` 有序：

1. **索引有序**：相同 user_id 的行在索引中连续存放
2. **松散索引扫描（Loose Index Scan）**：优化器对每个 user_id 只需读取第一行即可判定该 user_id 存在，跳过同 user_id 的其余行
3. **无需临时表**：`Using index for group-by` 表示直接在索引上完成去重，不创建临时表
4. **范围过滤受益**：visit_time 在索引第二列，可在索引内做范围判断

### 执行流程（优化后）

```
1. 从 idx_user_visit 索引扫描（有序）
2. 对每个 user_id：松散读取，遇到 visit_time > '2024-01-01' 即输出该 user_id
3. 跳到下一个 user_id（索引有序，无需全扫）
4. 无临时表、无额外排序
```

## 量化对比

| 指标 | bad.sql (无索引) | good.sql (有索引) | 提升 |
|------|------------------|-------------------|------|
| type | ALL | range | 全表 -> 索引范围 |
| rows | ~198,765 | ~66,124 | **减少 67%** |
| Extra | Using temporary | Using index for group-by | **消除临时表** |
| 耗时 | ~90 ms | ~15 ms | **约 6 倍** |

::: tip Using index for group-by 原理
当 DISTINCT/GROUP BY 的列是索引的最左前缀，且 SELECT 只包含这些列（或 MIN/MAX 聚合）时，
优化器使用**松散索引扫描**：对每个分组只读首行，跳过组内其余行。
这比紧凑扫描快得多，因为不需要读取所有数据。
:::

::: warning 索引列顺序很重要
本案例索引是 `(user_id, visit_time)`：
- DISTINCT user_id ✓（user_id 是前缀，可松散扫描）
- DISTINCT visit_time ✗（visit_time 不是前缀，无法松散扫描）
- WHERE visit_time > ? 在索引内可范围过滤，但去重仍依赖 user_id 有序
:::
