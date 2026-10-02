# EXPLAIN 参考结果 - good.sql（8.0 降序索引，正向扫描最优）

## MySQL 8.0（实测 8.0.46，20 万行数据）

需先执行 setup-good.sql 创建降序索引 `idx_type_created_desc (event_type, created_at DESC)`。

```
+----+-------------+--------------+-------+--------------------------------------------+-------------------------+---------+------+--------+----------+-----------------------+
| id | select_type | table        | type  | possible_keys                              | key                     | key_len | ref  | rows   | filtered | Extra                 |
+----+-------------+--------------+-------+--------------------------------------------+-------------------------+---------+------+--------+----------+-----------------------+
|  1 | SIMPLE      | t_event_log  | range | idx_type_created,idx_type_created_desc     | idx_type_created_desc   | 82      | NULL |  99292 |   100.00 | Using index condition |
+----+-------------+--------------+-------+--------------------------------------------+-------------------------+---------+------+--------+----------+-----------------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 索引范围扫描 |
| key | **`idx_type_created_desc`** | 优化器选择了降序索引 |
| rows | ~99,292 | 预估匹配行数（但 LIMIT 20 会提前终止） |
| Extra | `Using index condition` | 索引条件下推，无 filesort |

## 为什么快

8.0 真正支持降序索引，`idx_type_created_desc (event_type, created_at DESC)` 中 `created_at` 列按 **DESC 倒序** 物理存储。

查询 `WHERE event_type = 'LOGIN' ORDER BY created_at DESC LIMIT 20` 时：
1. 索引按 `event_type` 等值定位
2. 在该范围内 `created_at` 已是倒序排列
3. **正向扫描**索引即可，天然满足 `ORDER BY DESC`
4. LIMIT 20 可提前终止扫描，实际只读取 20 行

对比 bad 方案：
- bad (5.7)：升序索引 + ORDER BY DESC -> `Using filesort`（需排序全部匹配行）
- bad (8.0)：升序索引 + ORDER BY DESC -> `Backward index scan`（反向扫描，可用但非最优）
- good (8.0)：降序索引 + ORDER BY DESC -> 正向扫描，索引天然有序，最优方案

可通过 `SHOW INDEX FROM t_event_log` 验证：`idx_type_created_desc` 的 `created_at` 列 `Collation` 显示 `D`（Descending），表示降序索引生效。

## 量化对比

| 指标 | bad.sql 5.7 (升序) | bad.sql 8.0 (升序) | good.sql 8.0 (降序) | 提升 |
|------|--------------------|--------------------|---------------------|------|
| Extra | Using filesort | Backward index scan | Using index condition | **消除 filesort** |
| 扫描方式 | 排序全部匹配行 | 反向扫描索引 | 正向扫描索引 | 原生有序 |
| 耗时 | ~180 ms | ~4 ms | ~7 ms | 5.7 大幅提升 |

::: tip 降序索引判定
- `SHOW INDEX FROM t_event_log` 查看索引列的 `Collation` 字段
- 8.0 中 `created_at` 列显示 `D`（Descending）表示降序索引生效
- 5.7 中即使写了 DESC，`Collation` 仍显示 `A`（Ascending）

注意：8.0 的 `Backward index scan` 已经比 5.7 的 filesort 好很多。降序索引的核心价值在于：复合排序场景（如 `ORDER BY a ASC, b DESC`）中，升序索引无法同时满足两个方向的排序，必须 filesort；而混合方向索引 `(a ASC, b DESC)` 可完全消除 filesort。
:::
