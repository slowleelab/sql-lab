# LEFT JOIN 改 INNER JOIN 释放优化器

<CaseMeta difficulty="⭐⭐" category="JOIN" versions="5.7 & 8.0" :tags="['LEFT JOIN', 'INNER JOIN', '驱动表', '优化器', 'JOIN 顺序']" />

## 场景痛点

运营后台需要导出所有已支付订单及对应的用户昵称。订单表 100 万行，用户表 10 万行。开发同学习惯性地写下了 LEFT JOIN——"万一有的订单没有用户呢？"结果这条查询跑了 **3 秒多**：

```sql
SELECT o.id, o.order_no, o.amount, o.created_at, u.nickname
FROM t_order o
LEFT JOIN t_user u ON o.user_id = u.id
WHERE o.status = 1;
```

业务上已支付订单**一定存在**对应用户（支付前必须登录），LEFT JOIN 完全是多余的。但这个"以防万一"的写法，让优化器失去了重排 JOIN 顺序的自由，被迫以 100 万行的订单大表作为驱动表。

::: warning 真实场景
很多开发者把 LEFT JOIN 当作"安全默认值"，凡是 JOIN 都写 LEFT。但 LEFT JOIN 的语义是"保留左表全部行"，这个约束会锁死优化器的 JOIN 顺序选择。审查项目中的 LEFT JOIN，你会发现大量场景其实应该是 INNER JOIN。
:::

## 问题分析

### bad.sql

```sql
-- LEFT JOIN 语义要求保留左表全部行，优化器必须以 t_order 为驱动表
-- 即使 t_user 过滤性更好，优化器也无法重排 JOIN 顺序
-- 结果: 外层循环 100 万次（全表扫描订单表），逐行去用户表查找
SELECT o.id, o.order_no, o.amount, o.created_at, u.nickname
FROM t_order o
LEFT JOIN t_user u ON o.user_id = u.id
WHERE o.status = 1;
```

### EXPLAIN 结果

```
+----+-------------+-------+------------+------+----------------------+---------+---------+-----------------------+--------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys        | key     | key_len | ref                   | rows   | filtered | Extra       |
+----+-------------+-------+------------+------+----------------------+---------+---------+-----------------------+--------+----------+-------------+
|  1 | SIMPLE      | o     | NULL       | ALL  | idx_status           | NULL    | NULL    | NULL                  | 998512 |    20.00 | Using where |
|  1 | SIMPLE      | u     | NULL       | eq_ref| PRIMARY             | PRIMARY | 8       | sql_treasure.o.user_id|      1 |   100.00 | NULL        |
+----+-------------+-------+------------+------+----------------------+---------+---------+-----------------------+--------+----------+-------------+
```

### 为什么慢

LEFT JOIN 的语义是"保留左表全部行，右表无匹配则补 NULL"。这个语义约束导致：

1. **驱动表被锁死**：优化器必须以左表 t_order 为驱动表，无法重排 JOIN 顺序
2. **全表扫描 100 万行**：虽然 `status=1` 只匹配 20 万行，但优化器评估后认为走 idx_status 索引再回表的成本高于全表扫描，选择了 `type=ALL`
3. **80% 无效循环**：100 万次外层循环中，80 万行（待付/发货/完成/取消）被 WHERE 过滤掉，这些循环完全浪费
4. **无法利用用户表过滤性**：t_user 只有 10 万行且 95% 是正常用户，如果能从用户侧驱动，外层循环仅 9.5 万次

```
LEFT JOIN 执行流程:
1. 全表扫描 t_order（100 万行）          <- 驱动表被锁死
2. 每行检查 status = 1（80% 被丢弃）      <- 无效循环
3. 对剩下的 20 万行，逐行去 t_user 主键查找
```

实际耗时：约 **3200 ms**（实测 MySQL 8.0.46，100 万行订单表）。

::: tip 核心认知
LEFT JOIN 不只是"多保留几行"的问题——它改变了优化器的决策空间。LEFT JOIN 锁死驱动表，INNER JOIN 释放优化器。当业务语义允许时，INNER JOIN 给优化器的自由度就是性能的上限。
:::

## 优化方案

### good.sql

```sql
-- 业务确认: 已支付订单(status=1)一定存在对应用户，不存在孤儿订单
-- INNER JOIN 不保留任何一侧的未匹配行，优化器可自由选择驱动表
-- 优化器会评估: 从 t_user 过滤正常用户(9.5万) 驱动，还是从 t_order 过滤已支付(20万) 驱动
-- 最终选择代价更低的方案，外层循环次数大幅减少
SELECT o.id, o.order_no, o.amount, o.created_at, u.nickname
FROM t_order o
INNER JOIN t_user u ON o.user_id = u.id
WHERE o.status = 1;
```

### 原理

INNER JOIN 不保留任何一侧的未匹配行，优化器获得了完全的 JOIN 顺序自由度：

1. **优化器重新评估代价**：INNER JOIN 语义下，从哪侧驱动结果集相同，优化器自由选择代价最低的方案
2. **选择 idx_status 索引**：优化器发现 `status=1` 过滤后仅 20 万行，走 idx_status 索引 + 回表的代价低于全表扫描
3. **外层循环减少 80%**：从 100 万次降到 20 万次，每次循环都是有效的已支付订单
4. **语义等价前提**：业务上已支付订单一定有用户，LEFT JOIN 和 INNER JOIN 结果完全一致

```
INNER JOIN 执行流程:
1. 走 idx_status 索引找到 status=1 的订单（20 万行）  <- 优化器自由选择
2. 每行都是有效订单（filtered=100%）                  <- 零无效循环
3. 逐行去 t_user 主键查找（eq_ref，每次 1 行）
```

### 对比

| | bad.sql (LEFT JOIN) | good.sql (INNER JOIN) |
|---|---|---|
| 驱动表扫描方式 | ALL（全表扫描） | **ref（索引查找）** |
| 外层循环次数 | 998,512 | **199,702** |
| 无效循环 | 80%（80 万次） | **0%** |
| 驱动表 key | NULL | **idx_status** |
| 耗时 | ~3200 ms | **~800 ms** |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '998,512', Extra: 'Using where（filtered 仅 20%，80% 循环无效）' }"
  :good="{ type: 'ref', key: 'idx_status', rows: '199,702', Extra: 'NULL（filtered 100%，零无效循环）' }"
  improvement="外层循环从 100 万降到 20 万，耗时下降 4 倍"
/>

## 避坑指南

::: warning 注意事项

1. **确认业务语义**：改 INNER JOIN 前必须确认"左表每行在右表都有匹配"，否则结果集会少行。本例中已支付订单一定有用户，所以语义等价。

2. **LEFT JOIN 不是万能的**：很多开发者习惯默认写 LEFT JOIN"以防万一"，但这会锁死优化器。写 JOIN 前先想清楚：我真的需要保留左表未匹配的行吗？

3. **审查现有 SQL**：搜索项目中所有 LEFT JOIN，逐一确认是否真的需要保留左表未匹配行。你会发现大量可以改成 INNER JOIN 的场景。

4. **配合索引**：INNER JOIN 后优化器可能选择不同索引，确保相关列有合适索引。本例中 `idx_status` 在 INNER JOIN 下才被选中。

5. **5.7 中可强制干预**：如果 5.7 优化器仍选 ALL，可用 `STRAIGHT_JOIN` 或 `FORCE INDEX` 干预，但优先通过改写 JOIN 类型解决。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| LEFT JOIN 锁死驱动表 | ✅ 同样锁死 | ✅ 同样锁死 |
| INNER JOIN 自由重排 | ✅ 支持 | ✅ 支持 |
| 代价模型精确度 | 一般，可能仍选 ALL | 更精确，倾向选 idx_status |
| 优化器干预手段 | STRAIGHT_JOIN / FORCE INDEX | 同 5.7，但更少需要 |

::: tip 8.0 代价模型更聪明
两个版本的优化器在 INNER JOIN 下都能自由重排 JOIN 顺序，但 8.0 的代价模型更精确，选择 idx_status 索引的倾向更强。5.7 中如果优化器仍固执地选全表扫描，可以用 `FORCE INDEX (idx_status)` 推它一把。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 41-left-join-to-inner

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 41-left-join-to-inner --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 41-left-join-to-inner --no-seed
```
