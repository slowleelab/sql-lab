# 冗余索引清理

<CaseMeta difficulty="⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['冗余索引', '索引清理', '写入开销']" />

## 两个候选索引每次都要比较：冗余索引的写入放大
订单索引表上同时存在 `idx_user (user_id)` 和 `idx_user_created (user_id, created_at)` 两个索引。查询 `WHERE user_id = 12345` 时 EXPLAIN 的 `possible_keys` 列出两个候选索引，优化器每次都要做成本比较来选择--这看起来无害，但背后是实打实的写入放大。

```sql
-- 查询本身不慢，但 possible_keys 出现两个候选索引
SELECT id, user_id, order_no, status, created_at
FROM t_order_index
WHERE user_id = 12345;
```

问题在于 `idx_user (user_id)` 是 `idx_user_created (user_id, created_at)` 的**前缀冗余索引**--联合索引的最左前缀已经能完整覆盖 `WHERE user_id = ?` 的等值查询，单独的单列索引纯属浪费。每次 INSERT/UPDATE 都要维护两棵 B+ 树，20 万行数据白白多出约 1.6MB 索引空间，buffer pool 也被无谓占用。

这类问题在快速迭代的项目中极其普遍--先建了 `idx_user`，后来加了 `idx_user_created` 但忘了删旧的，时间一长没人敢动。

::: warning 真实场景
生产环境索引只增不减是常态。开发加索引快，删索引怕出事。久而久之表上堆了十几个索引，写入性能越来越差，却没人能说清每个索引是否还有用。冗余索引是"温水煮青蛙"式的性能债务。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 表上存在冗余索引 idx_user (user_id)
-- 优化器有两个候选索引 idx_user / idx_user_created，possible_keys 列出两个，增加选择成本
SELECT id, user_id, order_no, status, created_at
FROM t_order_index
WHERE user_id = 12345;
```

### EXPLAIN 结果

```
+----+-------------+----------------+------+--------------------------------+------------------+---------+-------+------+----------+-------+
| id | select_type | table          | type | possible_keys                  | key              | key_len | ref   | rows | filtered | Extra |
+----+-------------+----------------+------+--------------------------------+------------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | t_order_index  | ref  | idx_user,idx_user_created      | idx_user_created | 8       | const |   12 |   100.00 | NULL  |
+----+-------------+----------------+------+--------------------------------+------------------+---------+-------+------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 等值匹配索引 |
| possible_keys | `idx_user,idx_user_created` | **两个候选索引同时出现** |
| key | `idx_user_created` | 优化器最终选了联合索引 |
| Extra | NULL | 无额外操作（查询本身不慢） |

### 为什么慢

虽然查询本身性能尚可，但 `idx_user` 是 `idx_user_created (user_id, created_at)` 的**前缀冗余索引**，带来隐性危害：

1. **写入放大**：每次 INSERT/UPDATE 都要维护两份 user_id 索引，`idx_user` 纯属浪费
2. **空间浪费**：20 万行 × 8 字节 ≈ 1.6 MB 额外索引空间（不含 B+ 树节点开销）
3. **优化器困惑**：`possible_keys` 出现两个候选，每次都要评估成本做选择，增加解析开销
4. **维护负担**：DBA 容易误以为两个索引都在用，不敢清理

可通过 `sys.schema_redundant_indexes` 视图直接发现这类冗余索引：

```sql
SELECT * FROM sys.schema_redundant_indexes
WHERE table_schema = 'sql_treasure' AND table_name = 't_order_index';
```

::: warning 冗余索引判定
`idx(a)` 是 `idx(a,b)` 的冗余索引（左前缀完全相同），可安全删除。但 `idx(b)` 不是 `idx(a,b)` 的冗余，因为前缀不同，无法互相替代。
:::

::: tip 核心认知
联合索引 `(a, b)` 的最左前缀已覆盖 `WHERE a = ?` 查询，单独的 `idx(a)` 是冗余索引，只增加写入开销而不带来任何查询收益。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 删除冗余索引后查询（需先执行 setup-good.sql 删除 idx_user）
-- 仅剩 idx_user_created，possible_keys 更清晰，写入开销也降低
SELECT id, user_id, order_no, status, created_at
FROM t_order_index
WHERE user_id = 12345;
```

先执行 setup-good.sql 删除冗余索引：

```sql
-- setup-good.sql: 删除冗余前缀索引 idx_user，保留联合索引 idx_user_created
ALTER TABLE t_order_index DROP INDEX idx_user;
```

### 原理

删除冗余的 `idx_user` 后：

1. **possible_keys 只剩一个**：优化器无需再在两个索引间做成本比较
2. **查询能力不降级**：`idx_user_created (user_id, created_at)` 的前缀能完整覆盖 `WHERE user_id = ?` 的等值查询
3. **写入提速**：每次 INSERT 只维护一个 user_id 索引（减少一次 B+ 树插入）
4. **空间释放**：回收冗余索引占用的磁盘与内存（buffer pool）

### 对比

| | bad.sql (有冗余) | good.sql (已清理) |
|---|---|---|
| possible_keys 数量 | 2 | 1 |
| user_id 索引数量 | 2 | 1 |
| 单行 INSERT 索引维护 | 2 棵 B+ 树 | 1 棵 B+ 树 |
| 额外索引空间 | ~1.6 MB | 0 |

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_user_created', rows: '12', Extra: 'possible_keys: idx_user,idx_user_created' }"
  :good="{ type: 'ref', key: 'idx_user_created', rows: '12', Extra: 'possible_keys: idx_user_created（仅一个）' }"
  improvement="候选索引从 2 个减为 1 个，写入开销减半，释放冗余索引空间"
/>

## 避坑指南

::: warning 注意事项

1. **不是所有单列索引都是冗余的**。`idx(a)` 是 `idx(a,b)` 的冗余，但 `idx(b)` 不是--因为前缀不同。只有左前缀完全相同的索引才是冗余的，可安全删除。

2. **删除前用 INVISIBLE 索引灰度验证**。8.0 支持先将索引设为 `INVISIBLE`，观察一段时间确认无查询受影响后再 `DROP`。5.7 无此功能，建议先在测试环境验证。

3. **定期巡检而非一次性清理**。用 `sys.schema_redundant_indexes` 找冗余索引，用 `sys.schema_unused_indexes` 找长期未使用的索引，建立定期巡检机制。

4. **注意唯一索引的特殊性**。如果 `idx(a)` 是 UNIQUE 索引而 `idx(a,b)` 是普通索引，删除 `idx(a)` 会丢失唯一约束，不能简单当作冗余删除。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 冗余索引清理 | ✅ 手动 DROP INDEX | ✅ 手动 DROP INDEX |
| INVISIBLE 索引灰度验证 | ❌ 不支持 | ✅ 先隐身后删除 |
| `sys.schema_redundant_indexes` | ✅ 支持 | ✅ 支持 |
| `sys.schema_unused_indexes` | ✅ 支持 | ✅ 支持 |

::: tip 冗余索引清理建议
- 用 `sys.schema_redundant_indexes` 定期巡检
- 用 `sys.schema_unused_indexes` 找长期未使用的索引
- 删除前可先用 8.0 的 INVISIBLE 索引做灰度验证（见案例 13）
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 10-redundant-index-cleanup

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 10-redundant-index-cleanup --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 10-redundant-index-cleanup --no-seed
```
