# Hash Join vs BNL

<CaseMeta difficulty="⭐⭐⭐" category="JOIN" versions="8.0+" :tags="['Hash Join', 'BNL', '8.0新特性']" />

## 场景痛点

两张表 JOIN，被驱动表 JOIN 列没有索引。5.7 用 Block Nested Loop（BNL）性能极差，8.0 引入 Hash Join 改善了这种情况。

## 问题分析

```sql
-- bad.sql: 无索引 JOIN（8.0 走 Hash Join，5.7 走 BNL）
SELECT a.name, b.data
FROM t_a a JOIN t_b b ON b.a_id = a.id
WHERE a.val > 49000;
```

- **5.7 BNL**：把驱动表数据分批放入 join_buffer，被驱动表全表扫描与 buffer 中每行比较。复杂度 O(N×M)。
- **8.0 Hash Join**：先扫描小表建 hash 表，再扫描大表用 hash 查找。复杂度 O(N+M)。

## 优化方案

```sql
-- setup-good.sql: ALTER TABLE t_b ADD KEY idx_a_id (a_id);
-- good.sql: 有索引后走 Index Nested Loop Join（最优）
SELECT a.name, b.data
FROM t_a a JOIN t_b b ON b.a_id = a.id
WHERE a.val > 49000;
```

<ExplainCompare
  :bad="{ type: 'ALL (无索引)', key: 'NULL', rows: '100,000', Extra: 'Hash Join(8.0) / BNL(5.7)' }"
  :good="{ type: 'ref', key: 'idx_a_id', rows: '1 per lookup', Extra: 'Index Nested Loop' }"
  improvement="无索引Hash Join -> 有索引Nested Loop，最快"
/>

::: tip 8.0 Hash Join
Hash Join 是 8.0.18+ 引入的，用于替代无索引场景下的 BNL。虽然比 BNL 好很多，但有索引的 Nested Loop 仍然更快。**Hash Join 不是不建索引的理由**。
:::

## 避坑指南

::: warning 注意事项
1. **Hash Join 触发条件**：被驱动表无索引 + 非等值条件无法用 Hash Join。
2. **join_buffer_size**：Hash 表超过内存会落盘，调大 `join_buffer_size` 有帮助。
3. **强制禁用 Hash Join**：`SET optimizer_switch='hash_join=off'`（仅用于测试对比）。
:::

## 本地复现

```bash
./scripts/run-case.sh 35-hash-join-vs-bnl
```
