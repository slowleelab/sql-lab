# EXPLAIN 参考结果 - good.sql（STRAIGHT_JOIN 强制最优驱动顺序）

> 本案例无 setup-good.sql，bad/good 差异在于 `STRAIGHT_JOIN` 指定的 JOIN 顺序。

## MySQL 8.0（实测 8.0.46，10 万订单 + 30 万订单项 + 1 万商品）

```
+----+-------------+-------+------------+--------+--------------------+-------------+---------+--------------------+------+----------+-------------+
| id | select_type | table | partitions | type   | possible_keys      | key         | key_len | ref                | rows | filtered | Extra       |
+----+-------------+-------+------------+--------+--------------------+-------------+---------+--------------------+------+----------+-------------+
|  1 | SIMPLE      | o     | NULL       | ref    | idx_user_id        | idx_user_id | 8       | const              |    2 |   100.00 | NULL        |
|  1 | SIMPLE      | i     | NULL       | ref    | idx_order_id       | idx_order_id| 8       | test.o.id          |    3 |   100.00 | NULL        |
|  1 | SIMPLE      | p     | NULL       | eq_ref | PRIMARY,idx_category| PRIMARY    | 8       | test.i.product_id  |    1 |    10.00 | Using where |
+----+-------------+-------+------------+--------+--------------------+-------------+---------+--------------------+------+----------+-------------+
```

## 关键改进

| 步骤 | 字段 | 值 | 分析 |
|------|------|-----|------|
| 第一张表 `o` type | `ref` | `t_order_sj` 走 `idx_user_id` 索引，精确过滤 `user_id=100` |
| 第一张表 `o` rows | `2` | 只扫描约 2 行（user_id=100 的订单数） |
| 第二张表 `i` type | `ref` | `i.order_id = o.id` 走 `idx_order_id` 索引查找 |
| 第二张表 `i` rows | `3` | 每个订单约 3 个订单项，2 个订单共约 6 行 |
| 第三张表 `p` type | `eq_ref` | `p.id = i.product_id` 走主键等值查找 |
| 第三张表 `p` filtered | `10.00` | `p.category = '电子'` 过滤，约 10% 命中 |
| JOIN 顺序 | order → item → product | 小结果集驱动，每步中间结果集都很小 |

## 为什么快

`STRAIGHT_JOIN` 强制了 `t_order_sj → t_order_item_sj → t_product_sj` 的顺序：

1. 先从 `t_order_sj` 用 `idx_user_id` 索引过滤 `user_id = 100`，只扫描约 2 行
2. 对这 2 行，到 `t_order_item_sj` 用 `idx_order_id` 索引查找（`type=ref`），每次约 3 行，中间结果集约 2 × 3 = 6 行
3. 对这 6 行，到 `t_product_sj` 用主键查找（`type=eq_ref`），过滤 `category='电子'` 后剩约 1 行

对比 bad 方案：bad 先扫 30 万行 `t_order_item_sj`，做 30 万次 `t_product_sj` 主键查找 + 3 万次 `t_order_sj` 主键查找，最后才过滤掉 99.5%。good 方案把过滤前置到第一步，驱动行数从 30 万降到 2，后续每步的索引查找次数随之缩减约 5 个数量级。

核心原则：**让过滤后结果集最小的表做驱动表**，逐步放大，避免大中间结果集在 JOIN 流水线中传递。

实际耗时：约 **2 ms**。

## 量化对比

| 指标 | bad.sql（优化器选错） | good.sql（STRAIGHT_JOIN） | 提升 |
|------|---------|----------|------|
| 驱动表 | t_order_item_sj（30 万行） | t_order_sj（10 万行，过滤后 2 行） | 表缩小 3 倍，过滤后缩小 15 万倍 |
| 驱动表扫描行数 | ~298,734 | ~2 | **~15 万倍** |
| 过滤条件生效时机 | 最后一步（第 3 张表） | 第一步（驱动表） | 前置 |
| 第二张表访问 | eq_ref（主键，30 万次） | ref（idx_order_id，2 次） | 查找次数大降 |
| 中间结果集规模 | ~30 万 → ~3 万 → ~1500 | ~2 → ~6 → ~1 | 逐级控制 |
| JOIN 顺序 | item → product → order | order → item → product | 反转 |
| 耗时 | ~420 ms | ~2 ms | **210 倍** |

## 5.7 vs 8.0 差异

- `STRAIGHT_JOIN` 在两版都强制 JOIN 顺序，执行计划结构一致
- 两版都依赖 `idx_user_id`、`idx_order_id` 这两个二级索引完成 `ref` 查找，索引是 good 方案高效的前提
- 若无这两个索引，good 方案也会退化为全表扫描/BNL，因此本案例同时验证了"JOIN 顺序"与"被驱动表索引"的重要性
- 8.0 的优化器统计信息更准确，选错驱动表的概率低于 5.7，但 STRAIGHT_JOIN 仍是确保最优顺序的可靠手段
