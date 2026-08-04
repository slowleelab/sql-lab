# 派生条件下推

<CaseMeta difficulty="⭐⭐⭐" category="优化器" versions="8.0+" :tags="['派生表', '条件下推', '8.0优化', '物化']" />

## 100 万：10 万个用户
报表系统中常见的写法：先在子查询里 GROUP BY 汇总，外层再按条件过滤。在 MySQL 5.7 中，这种写法会先对 100 万行全量分组物化为临时表，再在外层过滤--明明只需要 1 个用户的数据，却分组了 10 万个用户。

```sql
-- 5.7: 先全量分组 100 万行，再过滤到 1 行
SELECT *
FROM (
    SELECT user_id, SUM(amount) AS total
    FROM t_order
    GROUP BY user_id
) t
WHERE t.user_id = 100;
```

::: warning 真实场景
FROM 子查询（派生表）在 5.7 中会被完整物化为临时表，外层 WHERE 条件无法下推。这是 5.7 升级 8.0 后最明显的"免费提速"场景之一。8.0 的派生条件下推（derived condition pushdown）自动将外层条件下推到子查询内部。
:::

## 问题分析

### bad.sql（5.7 行为）

```sql
SELECT *
FROM (
    SELECT user_id, SUM(amount) AS total
    FROM t_order
    GROUP BY user_id
) t
WHERE t.user_id = 100;
```

### EXPLAIN 结果（5.7）

```
+----+-------------+------------+-------+-------------+-------------+--------+----------+---------------------------------+
| id | select_type | table      | type  | key         | key_len     | rows   | filtered | Extra                           |
+----+-------------+------------+-------+-------------+-------------+--------+----------+---------------------------------+
|  1 | PRIMARY     | <derived2> | ALL   | NULL        | NULL        | 100000 |    10.00 | Using where                     |
|  2 | DERIVED     | t_order    | index | idx_user_id | idx_user_id | 998560 |   100.00 | NULL                            |
+----+-------------+------------+-------+-------------+-------------+--------+----------+---------------------------------+
```

### 为什么慢

5.7 的执行流程：

1. **派生表物化（id=2）**：对 `t_order` 全表 100 万行按 `user_id` 分组，生成 10 万行临时表
2. **外层过滤（id=1）**：在 10 万行临时表中扫描过滤 `user_id = 100`，`filtered=10.00` 表示只命中 10%

明明只需要 1 个用户的数据，却分组了 10 万个用户。99999 行的分组和物化完全浪费。

## 优化方案

### good.sql（8.0 自动优化）

```sql
-- 8.0 中同样的 SQL，优化器自动将 WHERE user_id=100 下推到派生表内部
-- 等价于: SELECT user_id, SUM(amount) FROM t_order WHERE user_id = 100 GROUP BY user_id
SELECT *
FROM (
    SELECT user_id, SUM(amount) AS total
    FROM t_order
    GROUP BY user_id
) t
WHERE t.user_id = 100;
```

### 原理

8.0 的派生条件下推（derived condition pushdown）：

1. 优化器检测到外层 `WHERE t.user_id = 100` 可以下推到派生表内部
2. 等价改写为：`SELECT user_id, SUM(amount) FROM t_order WHERE user_id = 100 GROUP BY user_id`
3. 只分组 `user_id=100` 的约 10 行数据，而非全量 100 万行
4. 物化行数从 10 万降到 1

### 对比

| | 5.7（无下推） | 8.0（自动下推） |
|---|---|---|
| 派生表 type | `index`（全索引扫描） | `ref`（索引精确查找） |
| 派生表 rows | ~998,560 | ~10 |
| 物化行数 | 100,000 | 1 |
| 外层过滤 | `Using where`（扫 10 万行） | 无需过滤 |
| 耗时 | ~680 ms | ~5 ms |

<ExplainCompare
  :bad="{ type: 'index', key: 'idx_user_id', rows: '998,560', Extra: '全量分组 100 万行，物化 10 万行临时表' }"
  :good="{ type: 'ref', key: 'idx_user_id', rows: '10', Extra: '条件下推，只分组 10 行，物化 1 行' }"
  improvement="扫描行数从 100 万降到 10，物化行数从 10 万降到 1，8.0 免费提速 100 倍+"
/>

## 避坑指南

::: warning 注意事项

1. **5.7 中需手动改写**。将外层条件移到子查询内部：
   ```sql
   -- 5.7 手动下推
   SELECT user_id, SUM(amount) AS total
   FROM t_order WHERE user_id = 100
   GROUP BY user_id;
   ```

2. **不是所有条件都能下推**。包含聚合函数的条件（如 `HAVING SUM(amount) > 100`）无法下推，因为依赖聚合结果。

3. **8.0 下推是自动的**，无需修改 SQL，升级 8.0 即可受益。但建议检查 EXPLAIN 确认下推生效。

4. **视图也有类似优化**。8.0 对视图的条件下推也做了增强，合并视图定义中的条件。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 派生条件下推 | ❌ 不支持 | ✅ 自动下推 |
| 派生表物化 | 总是物化 | ✅ 延迟物化（必要时才物化） |
| 视图合并 | 部分支持 | ✅ 增强合并算法 |

::: tip 8.0 升级免费提速
派生条件下推是 8.0 最重要的优化器改进之一。升级 8.0 后，大量 `FROM (子查询) WHERE` 写法会自动受益，无需改 SQL。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 78-derived-condition-pushdown

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 78-derived-condition-pushdown --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 78-derived-condition-pushdown --no-seed
```
