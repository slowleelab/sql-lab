# EXPLAIN FORMAT=JSON 深入解读成本与执行路径

<CaseMeta difficulty="⭐⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['EXPLAIN FORMAT=JSON', '成本估算', 'query_block', 'optimizer_trace', '执行计划']" />

## 12 列 EXPLAIN 看不到决策：FORMAT=JSON 揭开真相
经典的 `EXPLAIN`（12 列扁平表）只能看到最终选定的执行计划，**看不到优化器的决策过程**：
- 为什么选 `range` 而不是 `ref`？
- 为什么 `idx_a_b` 而不是 `idx_a`？
- 多个 JOIN 顺序的成本差异有多大？

`EXPLAIN FORMAT=JSON` 输出**树形结构 + 详细成本 + 优化器决策依据**，是定位"优化器决策错误"问题的杀手锏。

```sql
-- 经典 EXPLAIN 看不出成本
EXPLAIN SELECT * FROM t_order WHERE user_id = 100 AND status = 1 ORDER BY created_at LIMIT 10;
-- type=range, key=idx_user_status, rows=1000  -- 但为什么不是 ref？
```

::: warning 真实场景
"SQL 偶尔慢"或"索引选错"是 DBA 最棘手的问题。`EXPLAIN FORMAT=JSON` 配合 `OPTIMIZER_TRACE` 能完整还原优化器决策链：
- 候选索引列表
- 每种方案的估算成本
- 最终选择的依据
- 条件评估顺序（condition filtering）
:::

## 问题分析

### bad.sql — 经典 EXPLAIN 信息不足

```sql
-- bad 场景: 索引选错（实际可选多个索引）
EXPLAIN SELECT * FROM t_order
WHERE user_id BETWEEN 100 AND 200
  AND status = 1
  AND created_at > '2026-01-01'
ORDER BY created_at DESC
LIMIT 10;
```

经典 EXPLAIN 输出：

```
+----+---------+-------+-------+-------------------------+---------+---------+------+-------+-------------+
| id | table   | type  | key   | Extra                   | rows    | filtered|      |       |             |
+----+---------+-------+-------+-------------------------+---------+---------+------+-------+-------------+
|  1 | t_order | range | idx_ua | Using where; Using index| 50000   |    1.00 |      |       |             |
+----+---------+-------+-------+-------------------------+---------+---------+------+-------+-------------+
```

**问题**：
- 为什么选 `idx_ua`（user_id, amount）而不是 `idx_usc`（user_id, status, created_at）？
- `filtered=1.00` 是怎么算出来的？
- `rows=50000` 是基于什么统计信息？

经典 EXPLAIN **无法回答**。

## 优化方案

### good.sql — EXPLAIN FORMAT=JSON 全面诊断

```sql
-- good 方案: EXPLAIN FORMAT=JSON 输出树形结构
EXPLAIN FORMAT=JSON
SELECT * FROM t_order
WHERE user_id BETWEEN 100 AND 200
  AND status = 1
  AND created_at > '2026-01-01'
ORDER BY created_at DESC
LIMIT 10\G
```

输出（节选关键部分）：

```json
{
  "query_block": {
    "select_id": 1,
    "cost_info": {
      "query_cost": "125430.50"    -- ← 总成本
    },
    "ordering_operation": {
      "using_filesort": false,     -- ← 是否需要 filesort
      "table": {
        "table_name": "t_order",
        "access_type": "range",
        "possible_keys": ["idx_ua", "idx_usc", "idx_s_c"],  -- ← 候选索引
        "key": "idx_ua",           -- ← 实际选择
        "used_key_parts": ["user_id", "amount"],
        "rows_examined_per_scan": 50000,
        "rows_produced_per_join": 50000,
        "filtered": "1.00",
        "index_condition": "user_id between 100 and 200",
        "cost_info": {
          "read_cost": "85000.00",
          "eval_cost": "10000.00",
          "prefix_cost": "95000.00",
          "data_read_per_join": "120M"
        },
        "used_columns": ["id", "user_id", "status", "created_at", "amount"]
      }
    }
  }
}
```

**关键信息解读**：

| 字段 | 含义 | 价值 |
|------|------|------|
| `query_cost` | 整个查询的估算成本 | 对比不同方案的总成本 |
| `possible_keys` | 优化器考虑的所有索引 | 看是否漏选/错选 |
| `key` | 实际使用的索引 | 与 possible_keys 对比 |
| `rows_examined_per_scan` | 单次扫描行数 | 与 EXPLAIN 的 rows 字段对应 |
| `filtered` | 过滤后剩余比例 | 1.00 = 100% 命中 |
| `cost_info.read_cost` | IO 成本 | 占总成本主导 |
| `cost_info.eval_cost` | CPU 成本（行求值）| 通常 1/10 ~ 1/5 of read_cost |
| `using_filesort` | 是否需要额外排序 | true = 性能问题 |
| `used_columns` | 实际读取的列 | 覆盖索引时只列索引列 |

### 进阶：OPTIMIZER_TRACE 完整决策链

```sql
-- 最强诊断工具：记录优化器每一步决策
SET optimizer_trace = "enabled=on";
SELECT * FROM t_order
WHERE user_id BETWEEN 100 AND 200
  AND status = 1
ORDER BY created_at DESC
LIMIT 10;
SELECT * FROM information_schema.OPTIMIZER_TRACE\G

-- 输出包含:
-- 1. join_preparation: 表准备
-- 2. join_optimization: 优化阶段
--    - condition_processing: WHERE 条件处理
--    - substitute_generated_columns: 生成列替换
--    - table_dependencies: 表依赖分析
--    - ref_optimizer_key_uses: 候选索引评估
--    - rows_estimation: 行数估算
-- 3. join_execution: 最终执行计划
```

### 原理

**MySQL 优化器决策流程**：

```
SQL → 解析(parse) → 预处理(preprocess)
                    ↓
            候选执行计划（基于规则）
                    ↓
            成本估算(cost estimation)
                    ↓
            选择最低成本方案
                    ↓
            执行计划
```

**EXPLAIN FORMAT=JSON 把"成本估算结果"完整暴露**：

| 字段类型 | 经典 EXPLAIN | FORMAT=JSON |
|----------|-------------|-------------|
| 候选索引 | ❌ | ✅ `possible_keys` |
| 估算成本 | ❌ | ✅ `cost_info` |
| 过滤比例 | filtered 字段 | ✅ `filtered` (decimal) |
| 条件评估顺序 | ❌ | ✅ `attached_condition` |
| 是否回表 | Extra 提示 | ✅ `using_filesort` 等布尔 |
| 多表 JOIN 顺序 | ❌ | ✅ 嵌套 `query_block` |

### 典型使用场景

| 场景 | 诊断方法 |
|------|---------|
| 索引选错 | 对比 `possible_keys` vs `key`，检查 `rows_examined_per_scan` 差异 |
| 为什么不走索引 | 检查 `rows_examined_per_scan` 接近全表 → 优化器认为全表扫更快 |
| JOIN 顺序异常 | `FORMAT=JSON` 看 `query_block` 嵌套顺序 |
| filesort 慢 | `using_filesort: true` + `cost_info.sort_cost` |
| 临时表慢 | `using_temporary_table: true` + `temporary_table_cost` |
| 统计信息不准 | OPTIMIZER_TRACE 的 `rows_estimation` 段 |

<ExplainCompare
  :bad="{ type: 'classic', key: '12列扁平', rows: 'N/A', Extra: '只看到最终结果，看不到决策过程' }"
  :good="{ type: 'FORMAT=JSON', key: '成本树', rows: 'query_cost=125430', Extra: '完整成本/候选/条件评估' }"
  improvement="从'看到结果'到'理解原因'，索引选错诊断时间从 30 分钟降到 2 分钟"
/>

## 避坑指南

::: warning 注意事项

1. **JSON 输出很长**。复杂 JOIN 查询的 JSON 可能上千行，建议用 `mysql --vertical` 或 `\`G` 分页看。

2. **`OPTIMIZER_TRACE` 是会话级**。需 `SET optimizer_trace = "enabled=on"`，且仅记录**下一条** SQL。调试后建议关闭（`enabled=off`）。

3. **成本是相对值，不是绝对时间**。`query_cost=125430` 不代表"125 秒"，是优化器的内部单位。比较两条 SQL 时用比值（如 A 是 100、B 是 50 → B 快一倍）。

4. **`possible_keys` 不是越多越好**。理想情况是 1-3 个，太多的表可能需要清理冗余索引。

5. **结合 `SHOW WARNINGS` 看优化器改写**。`EXPLAIN ... ; SHOW WARNINGS;` 可看到优化器对 SQL 的等价改写（如外连接转内连接、IN 转 EXISTS 等）。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `EXPLAIN FORMAT=JSON` | ✅ 支持 | ✅ 支持 |
| `OPTIMIZER_TRACE` | ✅ 支持 | ✅ 支持（更详细） |
| `EXPLAIN ANALYZE` | ❌ | ✅ 5.7 部分版本实验性，8.0 GA（**8.0.18+ 推荐**） |
| 成本模型 | 5.7 默认 | 8.0.16+ 支持 `optimizer_cost_model=HYBRID`（更准确） |
| 范围优化器 | 基础 | 8.0 增强（多范围读取 MRR） |

::: tip 8.0 推荐：EXPLAIN ANALYZE
**`EXPLAIN ANALYZE`** 是 8.0.18+ 提供的**真实执行**版 EXPLAIN：
- 输出**实际行数**（`actual rows`）vs **估算**（`rows`）
- 输出**真实耗时**（`actual time`）
- 适合"线下复现"场景，能直接看到慢在哪一步
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 106-explain-format-json

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 106-explain-format-json --ver 5.7
```
