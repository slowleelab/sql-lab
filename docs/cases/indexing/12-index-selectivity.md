# 索引选择性评估

<CaseMeta difficulty="⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['选择性', '低基数列', '联合索引', 'cardinality']" />

## 订单状态表按 status 查询
订单状态表按 `status` 查询，`status` 只有 0/1/2 三个值（待付款/已付款/已关闭）。开发者给 `status` 建了索引 `idx_status`，以为查询 `WHERE status = 1` 能走索引加速。结果 EXPLAIN 显示 `type=ALL` 全表扫描--优化器明明知道有索引却不用。

```sql
-- status=1 命中约 10 万行（占总数 50%），优化器弃用索引
SELECT id, order_no, status, user_id, created_at
FROM t_order_status
WHERE status = 1;
```

20 万行数据中 `status=1` 占了约 50%（10 万行），走索引需要 10 万次随机回表（每次一次随机 I/O），而全表扫描是顺序 I/O，对大比例命中反而更快。优化器评估后选择全表扫描，`idx_status` 形同虚设。

根本问题是 `status` 是**低基数列**，单独建索引选择性极低（`COUNT(DISTINCT status) / COUNT(*) ≈ 0.000015`），索引无法有效过滤数据。

::: warning 真实场景
性别、状态、是否删除、是否激活--这些只有两三个值的字段在公司里几乎每张表都有。给它们单独建索引是新手最常犯的错误之一：索引建了但不被使用，白白浪费写入开销和空间，还给人"已优化"的错觉。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: status=1 命中约 10 万行（占总数 50%），选择性极低
-- 有 idx_status 但优化器评估走索引代价更高，最终全表扫描
SELECT id, order_no, status, user_id, created_at
FROM t_order_status
WHERE status = 1;
```

### EXPLAIN 结果

```
+----+-------------+-----------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table           | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+-----------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_order_status  | ALL  | idx_status    | NULL | NULL    | NULL | 198421 |    33.33 | Using where |
+----+-------------+-----------------+------+---------------+------+---------+------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | **`ALL`** | **全表扫描！**优化器放弃了索引 |
| possible_keys | `idx_status` | 知道有索引但不用 |
| key | `NULL` | 未使用任何索引 |
| rows | ~198,421 | 扫描几乎全表 |
| Extra | `Using where` | server 层逐行过滤 status |

### 为什么慢

`status` 只有 3 个值（0/1/2），是典型的**低基数列**：

```sql
-- 选择性 = 不同值数量 / 总行数
SELECT COUNT(DISTINCT status) / COUNT(*) AS selectivity FROM t_order_status;
-- 结果: 0.000015（极低）
```

优化器判断逻辑：
1. `status = 1` 命中约 10 万行（50%）
2. 走索引需 10 万次**随机回表**（每行一次随机 I/O）
3. 全表扫描是**顺序 I/O**，对大比例命中反而更快
4. 结论：走索引代价更高，放弃索引

::: warning 何时优化器会放弃索引
经验法则：当索引过滤后剩余行数超过全表的 **20%~30%** 时，优化器倾向于全表扫描。低基数列（性别、状态、是否删除）单独建索引几乎无用。
:::

::: tip 核心认知
索引选择性 = 不同值数量 / 总行数。选择性越接近 1，索引越有效。低基数列单独建索引，优化器评估后宁可全表扫描也不走索引。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 用联合索引 (status, user_id) 后，加上 user_id 过滤大幅缩小范围
-- 需先执行 setup-good.sql 建立 idx_status_user 联合索引
SELECT id, order_no, status, user_id, created_at
FROM t_order_status
WHERE status = 1 AND user_id = 12345;
```

先执行 setup-good.sql 建立联合索引：

```sql
-- setup-good.sql: 建立联合索引 (status, user_id)，用高基数列 user_id 提升整体选择性
ALTER TABLE t_order_status ADD KEY idx_status_user (status, user_id);
```

### 原理

`(status, user_id)` 联合索引把低基数的 `status` 与高基数的 `user_id` 组合：

1. **选择性大幅提升**：`status=1` 命中 10 万行，但 `status=1 AND user_id=12345` 只命中个位数行
2. **索引被真正使用**：复合选择性接近 1，优化器果断走索引
3. **扫描行数骤降**：从 19.8 万行降到 4 行

选择性计算：

```sql
-- 联合索引的选择性
SELECT COUNT(DISTINCT status, user_id) / COUNT(*) AS combined_sel
FROM t_order_status;
-- 结果接近 1（高选择性）
```

| 索引 | 选择性 | 优化器是否使用 |
|------|--------|----------------|
| idx_status | ~0.000015 | 否（全表扫描） |
| idx_status_user | ~0.99 | 是（ref 匹配） |

### 对比

| | bad.sql (单列索引) | good.sql (联合索引) |
|---|---|---|
| type | ALL | ref |
| rows | ~198,421 | ~4 |
| 扫描方式 | 顺序全表 | 索引定位 |
| 耗时 | ~80 ms | < 1 ms |

<ExplainCompare
  :bad="{ type: 'ALL', key: 'NULL', rows: '198,421', Extra: 'Using where' }"
  :good="{ type: 'ref', key: 'idx_status_user', rows: '4', Extra: 'NULL' }"
  improvement="扫描行从 19.8 万降到 4，全表扫描变索引精确查找"
/>

## 避坑指南

::: warning 注意事项

1. **低基数列不要单独建索引**。`status`、`gender`、`is_deleted` 这类只有几个值的列，单独建索引选择性极低，优化器几乎不会使用，反而增加写入开销。

2. **低基数列适合做联合索引前导列**。将低基数列放在联合索引最前面（如 `(status, user_id)`），后接高基数列，整体选择性由高基数列保证，且前导列的等值过滤能利用 ICP。

3. **如果只查低基数列本身，考虑汇总表**。如果业务只需要统计各状态的数量（`SELECT status, COUNT(*) ... GROUP BY status`），维护一个汇总表比依赖索引更高效。

4. **选择性不是唯一标准**。即使选择性低，如果查询总是带 `LIMIT 1` 或只需要判断"是否存在"，索引仍可能有用。要结合实际查询模式综合判断。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 优化器索引选择策略 | 基于成本评估 | 基于成本评估（更精确） |
| 联合索引提升选择性 | ✅ 有效 | ✅ 有效 |
| ICP（索引条件下推） | ✅ 5.6+ 支持 | ✅ 支持 |
| 直方图统计 | ❌ 不支持 | ✅ 8.0 新增，帮助优化器更准确评估 |

::: tip 低基数列索引设计原则
- 单独给低基数列（status、gender、is_deleted）建索引通常无意义
- 将低基数列作为联合索引**前导列**，后接高基数列，整体选择性由高基数列保证
- 低基数列适合做**前导列**是因为它常用于等值过滤，且能利用 ICP
- 若仅需统计各状态数量，考虑维护汇总表而非依赖索引
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 12-index-selectivity

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 12-index-selectivity --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 12-index-selectivity --no-seed
```
