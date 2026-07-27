# EXPLAIN 参考结果 - good.sql（三种 SQL 反模式的正确写法）

## MySQL 8.0（实测 8.0.46，30 万行数据）

---

### 正解 1: 只查必要列，减少回表数据量

```sql
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000;
```

```
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
| id | select_type | table       | partitions | type | possible_keys | key      | key_len | ref   | rows | filtered | Extra |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_anti_test | NULL       | ref  | idx_user      | idx_user | 8       | const |   30 |   100.00 | NULL  |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了 idx_user 索引定位 user_id=5000 |
| key | `idx_user` | 使用了单列索引 |
| key_len | `8` | BIGINT 占 8 字节 |
| ref | `const` | 与常量 5000 等值匹配 |
| rows | ~30 | 预估匹配约 30 行 |
| filtered | `100.00` | 等值条件过滤后全部命中 |
| Extra | `NULL` | 仍需回表（amount 不在索引中），但回表数据量减少 |

#### 为什么快

执行计划与 bad 方案 1（`SELECT *`）的 `type`/`key`/`rows` 完全一致，看似没有变化，但**回表读取的数据量天差地别**：

1. bad 方案回表读 `SELECT *`：要读 `order_no`(32B) + `amount`(5B) + `status`(1B) + `remark`(最多 100B) + `created_at`(5B)，每行约 140+ 字节
2. good 方案回表读 3 列：只读 `amount`(5B)（`id`、`user_id` 已在索引中），每行只需读取必要列
3. 30 行回表的数据传输量从约 4 KB 降至约 0.15 KB，**减少约 96%**

::: tip 覆盖索引的进一步优化
若查询只需 `id` 和 `user_id` 两列（`SELECT id, user_id FROM ...`），由于 InnoDB 二级索引自动附加主键 `id`，`idx_user(user_id)` 已能覆盖查询，Extra 将变为 `Using index`，**完全零回表**。这正是"按需取列"的终极形态。
:::

::: warning 不要被相同的执行计划迷惑
EXPLAIN 的 `type=ref + Extra=NULL` 与 `SELECT *` 看起来一样，但 EXPLAIN 不显示回表读取的列数和数据量。优化效果体现在回表 I/O 的数据量上，而非执行计划字段。配合 `Handler_read_rnd_next` 等状态变量可观测回表量差异。
:::

---

### 正解 2: UNION ALL 拆分 OR 条件

```sql
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000
UNION ALL
SELECT id, user_id, amount FROM t_anti_test WHERE status = 1 AND user_id != 5000;
```

```
+----+--------------+-------------+------------+------+---------------+--------------------+---------+-------+--------+----------+-------------+
| id | select_type  | table       | partitions | type | possible_keys | key                | key_len | ref   | rows   | filtered | Extra       |
+----+--------------+-------------+------------+------+---------------+--------------------+---------+-------+--------+----------+-------------+
|  1 | PRIMARY      | t_anti_test | NULL       | ref  | idx_user      | idx_user           | 8       | const |     30 |   100.00 | Using where |
|  2 | UNION        | t_anti_test | NULL       | ref  | idx_status    | idx_status         | 1       | const |  75000 |    99.99 | Using where |
+----+--------------+-------------+------------+------+---------------+--------------------+---------+-------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| select_type | `PRIMARY` / `UNION` | 两段独立查询，无 UNION RESULT 去重行 |
| 第一段 type | `ref` | 走 idx_user 定位 user_id=5000，约 30 行 |
| 第一段 key | `idx_user` | 单一索引，无合并 |
| 第二段 type | `ref` | 走 idx_status 定位 status=1 |
| 第二段 key | `idx_status`（或 idx_user_status） | 单一索引扫描 |
| rows | 30 + 75,000 | 两段分别预估行数，相加即结果集 |
| Extra | `Using where` | 第二段 `user_id != 5000` 在 server 层过滤 |

#### 为什么快

UNION ALL 将 OR 条件拆成两个独立查询，**每段都能走单一最优索引，无需 index_merge 合并去重**：

1. **第一段**：`user_id = 5000` 走 idx_user，约 30 行，定位精准
2. **第二段**：`status = 1 AND user_id != 5000` 走 idx_status，约 7.5 万行（与 bad 方案 status 侧匹配行数相同）
3. **无合并开销**：两段结果集无交集（第二段已排除 user_id=5000），用 UNION ALL 直接拼接，无需创建临时表去重
4. **无 index_merge 排序去重**：bad 方案的 index_merge 需要把 30 + 75000 个主键合并、排序、去重；good 方案两段各自独立，省去合并阶段

::: tip 为什么第二段排除 user_id != 5000
bad 方案 `user_id=5000 OR status=1` 的结果集是两条件的并集。拆分为 UNION ALL 后，第一段已包含所有 `user_id=5000` 的行，第二段只需补充 `status=1 但 user_id≠5000` 的行。否则 `user_id=5000 AND status=1` 的行会被两段各取一次，造成重复。这种"互斥拆分"让 UNION ALL 的"不去重"成为正确选择。

若无法保证互斥（如两条件可能命中同一行），应改用 UNION 去重，或接受业务层去重。但单表按主键拆分时，用 `AND 反向条件` 排除是标准做法。
:::

---

### 正解 3: COUNT(*) 统计总行数

```sql
SELECT COUNT(*) FROM t_anti_test WHERE user_id = 5000;
```

```
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
| id | select_type | table       | partitions | type | possible_keys | key      | key_len | ref   | rows | filtered | Extra     |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
|  1 | SIMPLE      | t_anti_test | NULL       | ref  | idx_user      | idx_user | 8       | const |   30 |   100.00 | Using index |
+----+-------------+-------------+------------+------+---------------+----------+---------+-------+------+----------+-----------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 走了 idx_user 索引 |
| key | `idx_user` | 使用了索引 |
| key_len | `8` | BIGINT 占 8 字节 |
| ref | `const` | 与常量 5000 等值匹配 |
| rows | ~30 | 预估匹配约 30 行 |
| filtered | `100.00` | 等值条件全部命中 |
| Extra | `Using index` | 覆盖索引，零回表 |

#### 为什么快且正确

`COUNT(*)` 与 bad 方案 3（`COUNT(remark)`）的执行计划表面上都是 `type=ref + Using index`，但语义和实现截然不同：

1. **语义正确**：`COUNT(*)` 统计匹配 `user_id=5000` 的**全部行数**（包括 remark 为 NULL 的行），返回 30；而 `COUNT(remark)` 只统计 remark 非 NULL 的行，返回约 24，漏掉约 6 行。
2. **优化器友好**：InnoDB 对 `COUNT(*)` 有专门优化，选择最小的索引扫描计数（此处选 idx_user，因 user_id=5000 仅 30 行，远小于全表扫描），只数索引条目，不读取行数据。
3. **不读列值**：`COUNT(*)` 不关心任何列的值，无需判断 NULL；`COUNT(remark)` 必须读取 remark 列判断是否为 NULL，多一步处理。

| 统计方式 | 返回值 | 语义 | 是否统计 NULL 行 |
|----------|--------|------|------------------|
| `COUNT(*)` | 30 | 匹配条件的总行数 | ✅ 是（正确） |
| `COUNT(remark)` | ~24 | remark 非 NULL 的行数 | ❌ 否（漏 NULL） |
| `COUNT(1)` / `COUNT(id)` | 30 | 匹配条件的总行数 | ✅ 是（id 非空） |

::: warning COUNT(*) vs COUNT(col) 的本质
- `COUNT(*)`：统计行数，不关心任何列，NULL 行也算。
- `COUNT(col)`：统计 col 列**非 NULL** 的行数，NULL 行被排除。
- `COUNT(1)` / `COUNT(常量)`：等价于 `COUNT(*)`，统计行数。
- `COUNT(主键)`：主键非空，等价于 `COUNT(*)`。

只有 `COUNT(col)`（col 为可空列）会漏 NULL 行。**统计总行数永远用 `COUNT(*)`**。
:::

---

## 量化对比：三种反模式 vs 正解

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

::: tip 三种反模式的本质
- 反模式 1 是**性能问题**：可优化但不致命，回表读无用列浪费 I/O。
- 反模式 2 是**性能问题**：index_merge 在两侧匹配行数悬殊时合并开销巨大。
- 反模式 3 是**正确性问题**：COUNT(col) 漏 NULL 行，结果直接错误，比性能问题更严重。

正确写法不仅更快，更重要的是语义正确。`COUNT(*)` 永远是统计行数的正解。
:::

## MySQL 5.7 差异

| 正解 | 5.7 行为 | 8.0 行为 |
|------|----------|----------|
| 只查必要列减少回表 | 一致，type=ref，Extra=NULL | 一致 |
| UNION ALL 拆分 OR | 一致，两段分别走单一索引 | 一致 |
| COUNT(*) 统计总行数 | 一致，Using index，语义正确 | 一致 |

5.7 与 8.0 在三种正解上的行为完全一致，优化器选择和 EXPLAIN 输出基本相同。三种反模式与正解的差异在两个版本上表现一致。
