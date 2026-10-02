# EXPLAIN 参考结果 - good.sql（STRAIGHT_JOIN 强制小表->中表->大表的最优顺序）

> 本案例无 setup-good.sql，bad/good 差异在于 `STRAIGHT_JOIN` 指定的 JOIN 顺序。
> good 强制 `t_small -> t_medium -> t_large`（小表驱动），每步都用小结果集驱动。
> 注意：bad 选 `s.*`，good 选 `l.*`，返回列不同。

## MySQL 8.0（t_small 1 千行 + t_medium 5 万行 + t_large 20 万行）

```
+----+-------------+-------+------------+------+---------------+---------------+---------+-----------+------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys | key           | key_len | ref       | rows | filtered | Extra       |
+----+-------------+-------+------------+------+---------------+---------------+---------+-----------+------+----------+-------------+
|  1 | SIMPLE      | s     | NULL       | ALL  | NULL          | NULL          |    NULL | NULL      | 1000 |    10.00 | Using where |
|  1 | SIMPLE      | m     | NULL       | ref  | idx_small_id  | idx_small_id  |       8 | test.s.id |   49 |   100.00 | NULL        |
|  1 | SIMPLE      | l     | NULL       | ref  | idx_medium_id | idx_medium_id |       8 | test.m.id |    4 |   100.00 | NULL        |
+----+-------------+-------+------------+------+---------------+---------------+---------+-----------+------+----------+-------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| 第一张表 `s` type | `ALL` | `t_small`（仅 1000 行）做驱动表，全表扫描但表很小 |
| 第一张表 `s` filtered | `10.00` | `s.val = 1` **第一时间生效**，1000 行过滤后约 100 行 |
| 第一张表 `s` rows | ~1000 | 驱动表只扫 1000 行（vs bad 的 20 万行） |
| 第二张表 `m` type | `ref` | `m.small_id = s.id` 走 `idx_small_id` 索引查找，每次约 49 行 |
| 第三张表 `l` type | `ref` | `l.medium_id = m.id` 走 `idx_medium_id` 索引查找，每次约 4 行 |
| JOIN 顺序 | small -> medium -> large | 小结果集驱动，每步中间结果集都很小 |

## 为什么快

`STRAIGHT_JOIN` 强制了 `t_small -> t_medium -> t_large` 的顺序，把过滤条件所在的小表放在最前面当驱动表：

1. 先全表扫描 `t_small` 的 1000 行（表小，扫描成本低），**立即用 `s.val = 1` 过滤**，只剩约 100 行。
2. 对这约 100 行，到 `t_medium` 用 `idx_small_id` 做索引查找（`type=ref`），每次约 49 行，中间结果集约 100 × 49 ≈ 4900 行。
3. 对这约 4900 行，到 `t_large` 用 `idx_medium_id` 做索引查找（`type=ref`），每次约 4 行，最终结果集约 4900 × 4 ≈ 19600 行。

对比 bad 方案：bad 先扫 20 万行 `t_large`，做 20 万次 `t_medium` 主键查找 + 20 万次 `t_small` 主键查找，最后才过滤掉 90%。good 方案把过滤前置到第一步，驱动行数从 20 万降到 100，后续每步的索引查找次数随之缩减约 3 个数量级。

核心原则：**让过滤后结果集最小的表做驱动表**，逐步放大，避免大中间结果集在 JOIN 流水线中传递。

## 量化对比

| 指标 | bad.sql（大表驱动） | good.sql（小表驱动） | 提升 |
|------|---------|----------|------|
| 驱动表 | t_large（20 万行） | t_small（1000 行） | 表缩小 200 倍 |
| 驱动表扫描行数 | ~199,723 | ~1000 | **~200 倍** |
| 过滤条件生效时机 | 最后一步（第 3 张表） | 第一步（驱动表） | 前置 |
| 第二张表访问 | eq_ref（主键，20 万次） | ref（idx_small_id，约 100 次） | 查找次数大降 |
| 中间结果集规模 | ~20 万行一路传递 | ~100 -> ~4900 -> ~19600 | 逐级控制 |
| JOIN 顺序 | large -> medium -> small | small -> medium -> large | 反转 |

## 5.7 vs 8.0 差异

- `STRAIGHT_JOIN` 在两版都强制 JOIN 顺序，执行计划结构一致
- 两版都依赖 `idx_small_id`、`idx_medium_id` 这两个二级索引完成 `ref` 查找，索引是 good 方案高效的前提
- 若无这两个索引，good 方案也会退化为全表扫描/BNL，因此本案例同时验证了“JOIN 顺序”与“被驱动表索引”的重要性
