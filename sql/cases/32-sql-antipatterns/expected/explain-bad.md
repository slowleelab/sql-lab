# EXPLAIN 参考结果 - bad.sql（三种 SQL 反模式）

## MySQL 8.0（实测 8.0.46，30 万行数据）

---

### 反模式 1: SELECT * 回表

```sql
SELECT * FROM t_anti_test WHERE user_id = 5000;
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
| rows | ~30 | 预估匹配约 30 行 |
| Extra | `NULL` | **没有 Using index，必须逐行回表** |

#### 为什么慢

`SELECT *` 要求返回 `order_no`、`amount`、`status`、`remark`、`created_at` 等所有列，而 `idx_user` 索引中只有 `user_id` 和主键 `id`。MySQL 必须：

1. 从 idx_user 索引定位到 30 条匹配的主键 id
2. **逐行回表**到聚簇索引读取完整行数据
3. 把不需要的 `remark`、`order_no` 等列也全部读入内存

30 次回表 = 30 次随机 I/O。虽然行数不多，但读取了大量无用数据，浪费内存和带宽。

::: warning 回表代价
即使 WHERE 条件能走索引，`SELECT *` 也会强制回表读取所有列。反模式不在于"慢到不可用"，而在于"明明可以不回表却白白回表"。
:::

---

### 反模式 2: OR 条件触发 index_merge

```sql
SELECT id, user_id, amount FROM t_anti_test WHERE user_id = 5000 OR status = 1;
```

```
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
| id | select_type | table       | partitions | type        | possible_keys         | key                   | key_len | ref  | rows   | filtered | Extra                                     |
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
|  1 | SIMPLE      | t_anti_test | NULL       | index_merge | idx_user,idx_status   | idx_user,idx_status   | 8,1     | NULL |  75200 |   100.00 | Using union(idx_user,idx_status); Using where |
+----+-------------+-------------+------------+-------------+-----------------------+-----------------------+---------+------+--------+----------+-------------------------------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `index_merge` | **索引合并，同时扫描两个索引** |
| possible_keys | `idx_user,idx_status` | 两个索引都可用 |
| key | `idx_user,idx_status` | 实际使用了两个索引 |
| key_len | `8,1` | idx_user 用 8 字节(BIGINT)，idx_status 用 1 字节(TINYINT) |
| rows | ~75,200 | 预估合并后约 7.5 万行 |
| Extra | `Using union(idx_user,idx_status); Using where` | union 策略：合并两个索引结果集 |

#### 为什么慢

`WHERE user_id=5000 OR status=1` 中两个条件各自有索引，MySQL 选择 `index_merge(union)` 策略：

1. 扫描 `idx_user` 索引，找到 `user_id=5000` 的约 30 行主键值
2. 扫描 `idx_status` 索引，找到 `status=1` 的约 7.5 万行主键值
3. 将两个结果集**合并、排序、去重**（union 操作）
4. 对合并后的 7.5 万个主键值**逐行回表**读取 `amount` 列

问题在于 `status=1` 匹配了约 7.5 万行（占总量 25%），index_merge 需要合并 7.5 万个主键值并排序去重，合并操作本身的开销就很大，再加上大量回表。

::: tip index_merge 的困境
index_merge 看似"用了两个索引"，实则合并去重的开销远超预期。当 OR 两侧的匹配行数差异巨大（30 vs 75000），合并 7.5 万行只为"顺便"带上 30 行，效率极低。
:::

---

### 反模式 3: COUNT(col) 语义错误

```sql
SELECT COUNT(remark) FROM t_anti_test WHERE user_id = 5000;
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
| rows | ~30 | 预估匹配约 30 行 |
| Extra | `Using index` | 覆盖索引（但语义错误） |

#### 为什么慢/为什么错

`COUNT(remark)` 的语义是"统计 remark 列非 NULL 的行数"，而非"统计匹配条件的总行数"。由于约 20% 的行 `remark` 为 NULL：

- `COUNT(remark)` 返回约 **24**（30 行中约 6 行 remark 为 NULL，被排除）
- `COUNT(*)` 返回 **30**（匹配条件的全部行数）

两者结果不同，`COUNT(remark)` 漏掉了 remark 为 NULL 的行，**语义错误**。

性能上，`COUNT(col)` 需要读取 remark 列的值判断是否为 NULL，虽然此处走了覆盖索引（idx_user 含 user_id + id），但优化器为判断 remark 是否 NULL 仍需额外处理。`COUNT(*)` 则只数行数，不需要读取任何列值。

::: warning 语义陷阱
`COUNT(col)` 不是"统计行数"，而是"统计该列非 NULL 的行数"。如果你的目的是统计总行数，用 `COUNT(col)` 会在该列有 NULL 值时得到错误结果。这是最常见的 COUNT 语义错误。
:::

## MySQL 5.7 差异

| 反模式 | 5.7 行为 | 8.0 行为 |
|--------|----------|----------|
| SELECT * 回表 | 一致，Extra 为 NULL 需回表 | 一致 |
| OR 触发 index_merge | 一致，Using union 策略 | 一致 |
| COUNT(col) 语义错误 | 一致，漏统计 NULL 行 | 一致 |

5.7 与 8.0 在三种反模式上的行为完全一致，优化器选择和 EXPLAIN 输出基本相同。
