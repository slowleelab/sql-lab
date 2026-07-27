# EXISTS vs IN 选择

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['EXISTS', 'IN', '子查询']" />

## 场景痛点

查询"技术部门的所有员工"，有两种写法：`IN` 子查询和 `EXISTS` 相关子查询。选哪个？

## 问题分析

```sql
-- bad.sql: IN 子查询（外表大、内表小时可能低效）
SELECT * FROM t_emp
WHERE dept_id IN (SELECT id FROM t_dept WHERE name LIKE '技术%');
```

`IN` 的执行逻辑：先执行子查询获取部门 ID 列表，再用列表去外表匹配。当外表（t_emp 30万行）远大于内表（t_dept 100行）时，IN 通常效率不错，但 5.7 某些场景下可能低效。

## 优化方案

```sql
-- good.sql: EXISTS 相关子查询
SELECT * FROM t_emp e
WHERE EXISTS (SELECT 1 FROM t_dept d WHERE d.id = e.dept_id AND d.name LIKE '技术%');
```

`EXISTS` 的执行逻辑：对外表每行执行一次子查询判断是否存在。当内表小且有索引时，每次判断是 O(1)。

<ExplainCompare
  :bad="{ type: 'ALL + subquery', key: 'idx_dept_id', rows: '300,000', Extra: 'IN 子查询' }"
  :good="{ type: 'ALL + dependent subquery', key: 'PRIMARY(idx_dept_id)', rows: '300,000 × 1', Extra: 'EXISTS 相关子查询' }"
  improvement="理解 IN vs EXISTS 原理，根据数据量选择"
/>

::: tip 选择原则
- **外表大、内表小** -> 用 `IN`（先查小表，再用结果过滤大表）
- **外表小、内表大** -> 用 `EXISTS`（遍历小表，逐行判断大表是否有匹配）
- **8.0 优化器**：通常会自动优化两者为相同的 semi-join 计划，差异不大
:::

## 避坑指南

::: warning 注意事项
1. **NOT IN 的 NULL 陷阱**：`NOT IN (1, 2, NULL)` 返回空结果！用 `NOT EXISTS` 替代。
2. **EXISTS 只判断存在性**：子查询 `SELECT 1` 即可，不需要 `SELECT *`。
3. **8.0 半连接优化**：8.0 会自动将 IN/EXISTS 优化为 semi-join，通常不需要手动改写。
:::

## 本地复现

```bash
./scripts/run-case.sh 23-exists-vs-in
```
