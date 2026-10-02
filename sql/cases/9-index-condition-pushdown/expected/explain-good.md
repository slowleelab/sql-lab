# EXPLAIN 参考结果 - good.sql (ICP 开启)

## MySQL 8.0（实测 8.0.46，20 万行数据）

```
+----+-------------+------------+-------+----------------+----------------+---------+------+-------+----------+-----------------------+
| id | select_type | table      | type  | possible_keys  | key            | key_len | ref  | rows  | filtered | Extra                 |
+----+-------------+------------+-------+----------------+----------------+---------+------+-------+----------+-----------------------+
|  1 | SIMPLE      | t_user_icp | range | idx_prefix_name| idx_prefix_name| 220     | NULL | 17682 |   100.00 | Using index condition |
+----+-------------+------------+-------+----------------+----------------+---------+------+-------+----------+-----------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 同 bad |
| key | `idx_prefix_name` | 同 bad |
| rows | ~17,682 | 同 bad（预估扫描行数一样） |
| Extra | **`Using index condition`** | **ICP 生效！条件在索引层过滤** |

## 为什么快

开启 ICP 后，MySQL 将 `name LIKE '张%'` 条件**下推到存储引擎层**，在索引上直接判断：

1. 从 `idx_prefix_name` 索引扫描 `phone_prefix = '1380'` 的行
2. **在索引上**用 `name LIKE '张%'` 过滤（不回表！）
3. 只有匹配的行才回表读取完整数据

对比：
- bad（ICP off）：4 万次回表 -> server 层过滤 -> 保留 2000 行
- good（ICP on）：索引层过滤 -> 只有 2000 次回表

## 量化对比

| 指标 | bad.sql (ICP off) | good.sql (ICP on) | 提升 |
|------|-------------------|-------------------|------|
| Extra | Using where | Using index condition | ICP 生效 |
| 回表次数 | ~17,682 | ~2,000（估计） | **减少 ~88%** |
| 耗时 | 120 ms | 45 ms | **2.7 倍** |

::: tip ICP 判定
Extra 显示 `Using index condition` = ICP 开启（好）
Extra 显示 `Using where` = ICP 关闭或条件无法下推（差）
:::
