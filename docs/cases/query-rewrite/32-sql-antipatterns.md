# SQL 反模式与正确写法量化对比

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['反模式', 'SELECT *', 'OR条件', 'COUNT', '覆盖索引']" />

## 场景痛点

订单系统上线后，慢查询日志里反复出现几条"看起来没问题"的 SQL。表只有 30 万行，索引也都建了，但就是有零星的性能抖动和莫名其妙的统计数据对不上。逐一排查后发现，开发写了三种常见的 SQL 反模式：

- **写法 A**：`SELECT * FROM t_anti_test WHERE user_id = 5000` -- 明明只用到几个字段，却把 `remark`、`order_no` 等不需要的列全读出来，白白回表读了大量无用数据。
- **写法 B**：`SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000 OR status = 1` -- OR 两侧都有索引，看似能走 index_merge，但 `status=1` 匹配了 7.5 万行（占 25%），合并去重的开销远超预期。
- **写法 C**：`SELECT COUNT(remark) FROM t_anti_test WHERE user_id = 5000` -- 本意是"统计 user_id=5000 的订单数"，结果因为约 20% 的行 `remark` 为 NULL 被漏掉，统计数比实际少了 6 行。

问题根源不在某一条 SQL 是否"慢"，而在**写法本身违背了正确性和高效性原则**：回表读无用列、OR 触发低效合并、COUNT(col) 漏 NULL。每种反模式都有对应的正确写法，性能和正确性都能显著提升。

::: warning 真实场景
这三种反模式在生产环境中无处不在：后端开发者图省事写 `SELECT *`；前端拼接查询条件天然写出 OR；统计接口习惯性用 `COUNT(字段名)`。它们都不会立刻让系统崩掉，而是像慢性病一样持续浪费 I/O、拖慢高峰期响应、制造"数据对不上"的疑难杂症。本案例对三种反模式做量化对比，给出正确写法和可观测的提升幅度。
:::

## 问题分析

### bad.sql

```sql
-- ============================================================
-- 反模式 1: SELECT * 导致回表
-- 即使 WHERE 走了 idx_user 索引定位到行，SELECT * 要求返回所有列，
-- 而索引中只含 user_id + id，order_no/amount/status/remark/created_at
-- 都不在索引中，必须逐行回表到聚簇索引读取完整行，无法走覆盖索引。
-- 30 万行表中 user_id=5000 约匹配 30 行，每行都需回表。
-- ============================================================
SELECT * FROM t_anti_test WHERE user_id = 5000;

-- ============================================================
-- 反模式 2: OR 条件可能导致 index_merge（低效）
-- WHERE user_id=5000 OR status=1，两个条件各自有索引 idx_user 和 idx_status。
-- 优化器选择 index_merge(union)：分别扫描两个索引，再合并去重。
-- status=1 匹配约 7.5 万行（占 25%），合并后结果集巨大，
-- index_merge 的合并去重开销 + 大量回表，远不如拆分为 UNION ALL。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000 OR status = 1;

-- ============================================================
-- 反模式 3: COUNT(col) 语义错误
-- COUNT(remark) 统计的是 remark 列非 NULL 的行数，而非匹配条件的总行数。
-- 约 20% 的行 remark 为 NULL，COUNT(remark) 会漏掉这些行，
-- 得到的数字小于实际匹配行数，语义错误。
-- 且 COUNT(col) 无法享受 InnoDB 对 COUNT(*) 的优化（如仅扫描最小索引）。
-- ============================================================
SELECT COUNT(remark) FROM t_anti_test WHERE user_id = 5000;
```

### EXPLAIN 结果

**反模式 1: SELECT * 回表**

```
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
| id | select_type | table       | partitions | type | possible_keys | key      | key_len | ref   | rows | filtered | Extra |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_anti_test | NULL       | ref  | idx_user      | idx_user | 8       | const |   30 |   100.00 | NULL  |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
```

执行计划看似正常（`type=ref` 走了 idx_user，`rows=30`），但 `Extra=NULL` 说明**必须逐行回表**。问题不在索引定位，而在回表读取的数据量。

**反模式 2: OR 触发 index_merge**

```
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
| id | select_type | table       | partitions | type        | possible_keys         | key                   | key_len | ref  | rows   | filtered | Extra                                     |
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
|  1 | SIMPLE      | t_anti_test | NULL       | index_merge | idx_user,idx_status   | idx_user,idx_status   | 8,1     | NULL |  75200 |   100.00 | Using union(idx_user,idx_status); Using where |
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
```

`type=index_merge` 看似"用了两个索引"，实则合并 7.5 万行只为带上 30 行，合并去重开销巨大。

**反模式 3: COUNT(col) 语义错误**

```
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
| id | select_type | table       | partitions | type | possible_keys | key      | key_len | ref   | rows | filtered | Extra     |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
|  1 | SIMPLE      | t_anti_test | NULL       | ref  | idx_user      | idx_user | 8       | const |   30 |   100.00 | Using index |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
```

执行计划漂亮（`Using index` 覆盖索引），但 `COUNT(remark)` 返回约 24，而实际匹配 30 行，**漏掉了 remark 为 NULL 的 6 行**。

### 为什么慢/为什么错

三种反模式的病灶各不相同：

**反模式 1（SELECT * 回表）-- 性能浪费：**

1. 从 idx_user 索引定位到 30 条匹配的主键 id
2. **逐行回表**到聚簇索引读取完整行数据
3. 把不需要的 `remark`、`order_no` 等列也全部读入内存

30 次回表 = 30 次随机 I/O，每行读约 140 字节，其中 `remark`（最多 100 字节）等列根本用不到。虽不至于慢到不可用，但回表数据量浪费明显。

**反模式 2（OR 触发 index_merge）-- 合并开销：**

1. 扫描 `idx_user` 索引，找到 `user_id=5000` 的约 30 行主键值
2. 扫描 `idx_status` 索引，找到 `status=1` 的约 7.5 万行主键值
3. 将两个结果集**合并、排序、去重**（union 操作）
4. 对合并后的 7.5 万个主键值**逐行回表**读取 `amount` 列

`status=1` 匹配了约 7.5 万行（占总量 25%），index_merge 需要合并 7.5 万个主键值并排序去重，合并操作本身的开销就很大，再加上大量回表。

**反模式 3（COUNT(col) 语义错误）-- 结果错误：**

`COUNT(remark)` 的语义是"统计 remark 列非 NULL 的行数"，而非"统计匹配条件的总行数"。由于约 20% 的行 `remark` 为 NULL：

- `COUNT(remark)` 返回约 **24**（30 行中约 6 行 remark 为 NULL，被排除）
- `COUNT(*)` 返回 **30**（匹配条件的全部行数）

两者结果不同，`COUNT(remark)` 漏掉了 remark 为 NULL 的行，**语义错误**。这比性能问题更严重--性能慢还能调优，结果错会让业务报表失真。

::: tip 三种反模式的本质差异
- 反模式 1 是**性能问题**：可优化但不致命，回表读无用列浪费 I/O。
- 反模式 2 是**性能问题**：index_merge 在两侧匹配行数悬殊时合并开销巨大。
- 反模式 3 是**正确性问题**：COUNT(col) 漏 NULL 行，结果直接错误，比性能问题更严重。
:::

## 优化方案

### good.sql

```sql
-- ============================================================
-- 正解 1: 只查必要列，走覆盖索引避免回表
-- id, user_id 两个列都在 idx_user 索引中（InnoDB 二级索引自动附加主键 id），
-- 虽然 amount 不在索引中仍需回表，但避免了 SELECT * 读取 remark 等
-- 不需要的列，回表读取的数据量大幅减少。
-- 若只需 id 和 user_id，则完全走覆盖索引（Using index），零回表。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000;

-- ============================================================
-- 正解 2: UNION ALL 拆分 OR 条件
-- 将 OR 拆为两个独立查询，每个查询都能高效走单一索引：
-- 第一段走 idx_user(user_id=5000)，约 30 行；
-- 第二段走 idx_status(status=1 AND user_id!=5000)，虽然 status=1 行多，
-- 但 UNION ALL 让优化器对两段分别选择最优索引，避免 index_merge 合并开销。
-- 两段结果无交集（第二段排除 user_id=5000），用 UNION ALL 无需去重。
-- ============================================================
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000
UNION ALL
SELECT id, user_id, amount FROM t_anti_test WHERE status = 1 AND user_id != 5000;

-- ============================================================
-- 正解 3: COUNT(*) 统计总行数
-- COUNT(*) 统计匹配条件的全部行数（包括 remark 为 NULL 的行），语义正确。
-- InnoDB 对 COUNT(*) 有特殊优化：选择最小的索引扫描计数，
-- 且不读取行数据（只数索引条目），比 COUNT(col) 更高效。
-- ============================================================
SELECT COUNT(*) FROM t_anti_test WHERE user_id = 5000;
```

### 原理

三种正解分别从"减少回表数据量"、"消除合并开销"、"修正统计语义"三个角度修正反模式：

**正解 1（只查必要列）-- 减少回表数据量：**

执行计划与 bad 方案 1 的 `type`/`key`/`rows` 完全一致（都是 `ref + idx_user + 30 行`），但**回表读取的数据量天差地别**：

1. bad 方案回表读 `SELECT *`：包含 `order_no`(32B) + `amount`(5B) + `status`(1B) + `remark`(最多 100B) + `created_at`(5B)，每行约 140+ 字节
2. good 方案回表读 3 列：只读 `amount`(5B)（`id`、`user_id` 已在索引中），每行只需读取必要列
3. 30 行回表的数据传输量从约 4 KB 降至约 0.15 KB，**减少约 96%**

若查询只需 `id` 和 `user_id`（`SELECT id, user_id FROM ...`），由于 InnoDB 二级索引自动附加主键，`idx_user(user_id)` 已能覆盖查询，Extra 变为 `Using index`，**完全零回表**。

**正解 2（UNION ALL 拆分）-- 消除合并开销：**

UNION ALL 将 OR 拆成两段独立查询，**每段走单一最优索引，无需 index_merge 合并去重**：

1. 第一段 `user_id=5000` 走 idx_user，约 30 行，定位精准
2. 第二段 `status=1 AND user_id!=5000` 走 idx_status，约 7.5 万行
3. 两段结果无交集（第二段已排除 user_id=5000），用 UNION ALL 直接拼接，无需临时表去重
4. 省去 index_merge 的"合并 7.5 万主键 + 排序 + 去重"阶段

第二段为何排除 `user_id != 5000`？因为第一段已包含所有 `user_id=5000` 的行，第二段只需补充 `status=1 但 user_id≠5000` 的行，否则 `user_id=5000 AND status=1` 的行会被两段各取一次造成重复。这种"互斥拆分"让 UNION ALL 的"不去重"成为正确选择。

**正解 3（COUNT(\*)）-- 修正统计语义：**

`COUNT(*)` 与 bad 方案 3 的执行计划表面都是 `type=ref + Using index`，但语义和实现截然不同：

1. **语义正确**：`COUNT(*)` 统计匹配 `user_id=5000` 的全部行数（包括 remark 为 NULL 的行），返回 30；`COUNT(remark)` 只统计 remark 非 NULL 的行，返回约 24
2. **优化器友好**：InnoDB 对 `COUNT(*)` 专门优化，选择最小的索引扫描计数（此处选 idx_user，30 行），只数索引条目，不读取行数据
3. **不读列值**：`COUNT(*)` 不关心任何列的值，无需判断 NULL；`COUNT(remark)` 必须读取 remark 列判断是否为 NULL

### EXPLAIN 结果（正解）

```
正解 1: SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000;
type=ref, key=idx_user, key_len=8, ref=const, rows=30, filtered=100.00, Extra=NULL
（仍需回表读 amount，但回表数据量减少 96%；若只查 id+user_id 则 Using index）

正解 2: UNION ALL 拆分
第一段: type=ref, key=idx_user, rows=30, Extra=Using where
第二段: type=ref, key=idx_status, rows=75000, Extra=Using where
（两段分别走单一索引，无 index_merge，无 UNION RESULT 去重行）

正解 3: SELECT COUNT(*) FROM t_anti_test WHERE user_id = 5000;
type=ref, key=idx_user, key_len=8, ref=const, rows=30, filtered=100.00, Extra=Using index
（覆盖索引零回表，且语义正确，统计全部匹配行）
```

<ExplainCompare
  :bad="{ type: 'index_merge', key: 'idx_user,idx_status', rows: '75,200', Extra: 'Using union; Using where' }"
  :good="{ type: 'ref (两段)', key: 'idx_user + idx_status', rows: '30 + 75,000', Extra: '分别走单一索引，无合并开销' }"
  improvement="消除 index_merge 合并去重开销，UNION ALL 拆分让每段走最优索引"
/>

## 量化对比

| 反模式 | bad 方案 | good 方案 | 核心差异 | 提升维度 |
|--------|----------|-----------|----------|----------|
| 1. SELECT * 回表 | `SELECT *` 回表读全部列（~140B/行） | `SELECT id,user_id,amount` 回表读必要列（~5B/行） | 回表数据量减少约 96% | **回表 I/O** |
| 2. OR 触发 index_merge | `index_merge` 合并 7.5 万主键排序去重 + 回表 | `UNION ALL` 两段分别走单一索引，无合并 | 消除 index_merge 合并去重开销 | **合并开销** |
| 3. COUNT(col) 语义错误 | `COUNT(remark)` 返回 ~24，漏 NULL 行 | `COUNT(*)` 返回 30，统计全部行 | 语义正确 + 优化器选择最小索引 | **正确性 + 性能** |

### 性能数据（30 万行表，user_id=5000 约 30 行）

| 方案 | 扫描行数 | 回表次数 | 额外开销 | 耗时(估) | 正确性 |
|------|----------|----------|----------|----------|--------|
| bad 1: SELECT * | 30 | 30（读全列） | 读 remark 等无用列 | ~0.4 ms | ✅ |
| good 1: 只查 3 列 | 30 | 30（读 amount） | 无 | ~0.3 ms | ✅ |
| bad 2: index_merge | 75,200 | 75,200 | 合并 + 排序 + 去重 | ~80 ms | ✅ |
| good 2: UNION ALL | 30 + 75,000 | 30 + 75,000 | 无合并（两段独立） | ~55 ms | ✅ |
| bad 3: COUNT(remark) | 30 | 0（Using index） | 判断 remark NULL | ~0.3 ms | ❌ 漏 NULL |
| good 3: COUNT(*) | 30 | 0（Using index） | 无 | ~0.2 ms | ✅ |

核心结论：
- **反模式 1** 的代价是回表数据量浪费（不慢，但可避免）；若只查索引列可完全零回表。
- **反模式 2** 的代价是 index_merge 合并开销（status=1 占 25% 数据量，合并 7.5 万行只为带上 30 行，极不划算）。
- **反模式 3** 的代价是语义错误（结果直接错），性能差异反而是次要问题。

## 避坑指南

::: warning 注意事项

1. **永远不要在业务查询中使用 SELECT \***。即使 WHERE 走了索引，`SELECT *` 也会强制回表读取所有列（包括 `remark` 等大字段）。明确列出所需列，能走覆盖索引就走覆盖索引。尤其含 TEXT/BLOB 的表，`SELECT *` 还会触发溢出页 I/O（详见案例 43）。

2. **OR 两侧匹配行数悬殊时拆分为 UNION ALL**。`user_id=5000`(30 行) OR `status=1`(7.5 万行) 这种悬殊场景，index_merge 合并 7.5 万行只为带上 30 行，效率极低。拆为两段独立查询，各走单一索引，用 `AND 反向条件` 保证两段无交集后用 UNION ALL 拼接。

3. **统计行数永远用 COUNT(\*)**。`COUNT(col)` 统计的是 col 非 NULL 的行数，可空列有 NULL 值时会漏统计。`COUNT(*)` / `COUNT(1)` / `COUNT(主键)` 才是统计总行数。这是最常见的 COUNT 语义错误，会让报表数据失真。

4. **UNION ALL 拆分要用"互斥条件"保证无重复**。拆分 OR 为 UNION ALL 时，第二段要用 `AND 反向条件` 排除第一段已覆盖的行（如 `AND user_id != 5000`），否则两段命中同一行会重复。若无法保证互斥，改用 UNION 去重，或接受业务层去重。

5. **不要被相同的执行计划迷惑**。`SELECT *` 和 `SELECT 必要列` 的 EXPLAIN 看起来一样（都是 `ref + NULL`），但回表读取的列数和数据量差异巨大。EXPLAIN 不显示回表数据量，需配合 `Handler_read_rnd_next` 等状态变量观测。

6. **OR 两侧是同一列时优先用 IN**。`status=1 OR status=2` 应改写为 `status IN (1,2)`，优化器对 IN 有专门优化，比 OR 更高效。OR 改 UNION 的场景适用于"两侧是不同列"的情况。

:::

::: tip 本案例与案例 06、案例 26 的关系
三个案例都涉及 OR/UNION，但角度不同，互补不重复：
- **案例 06（OR 条件与索引合并）**：OR 一侧无索引导致全表扫描，重点是"OR 两侧必须有索引才能用 index_merge"，治标是给缺失索引的列建索引或改 UNION。
- **案例 26（UNION vs UNION ALL）**：两表合并查询误用 UNION 导致临时表去重，重点是"UNION 自动去重的临时表开销"，治标是确认无重复后用 UNION ALL。
- **案例 32（SQL 反模式对比）**：OR 两侧都有索引但匹配行数悬殊，index_merge 合并开销巨大；同时覆盖 SELECT * 和 COUNT(col) 两类反模式，做量化对比。

简言之：案例 06 治"OR 一侧无索引"，案例 26 治"UNION 误去重"，案例 32 治"OR 两侧行数悬殊 + 顺带覆盖 SELECT * / COUNT(col)"。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| SELECT * 回表行为 | 一致，Extra=NULL 需回表 | 一致 |
| OR 触发 index_merge | 一致，Using union 策略 | 一致 |
| UNION ALL 拆分优化 | 一致，两段分别走单一索引 | 一致 |
| COUNT(col) 语义错误 | 一致，漏统计 NULL 行 | 一致 |
| COUNT(*) 优化器选择最小索引 | ✅ 支持 | ✅ 支持 |
| 覆盖索引（Using index） | ✅ 支持 | ✅ 支持 |

::: tip 5.7 与 8.0 行为一致
三种反模式与正解在 5.7 和 8.0 上的行为完全一致，优化器选择和 EXPLAIN 输出基本相同。这意味着本案例的优化建议在两个版本上通用，无需针对版本调整写法。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 32-sql-antipatterns

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 32-sql-antipatterns --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 32-sql-antipatterns --no-seed
```

::: tip 复现要点
本案例重点观察 `bad.sql` 三个反模式与 `good.sql` 三个正解的 EXPLAIN 与结果差异：
- 反模式 1（SELECT *）vs 正解 1（只查 3 列）：执行计划相同，但回表数据量差异需通过 `SHOW STATUS LIKE 'Handler_read_rnd_next'` 观测。
- 反模式 2（index_merge）vs 正解 2（UNION ALL）：`type=index_merge` 一行变 `type=ref` 两行，`rows=75200` 拆为 `30 + 75000`。
- 反模式 3（COUNT(remark)）vs 正解 3（COUNT(*)）：执行计划都是 Using index，但 `SELECT COUNT(remark)` 返回 ~24，`SELECT COUNT(*)` 返回 30，结果直接可见差异。

可在 `expected/explain-bad.md` 和 `expected/explain-good.md` 查看完整 EXPLAIN 参考结果。
:::
