# COUNT(*) 慢查询优化

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['COUNT', '汇总表', '物化视图']" />

## 场景痛点

后台仪表盘显示订单总数，`SELECT COUNT(*) FROM t_order_count WHERE status=1` 在 50 万行表上要 400ms。每次刷新都卡。

## 问题分析

```sql
-- bad.sql: 大表实时 COUNT
SELECT COUNT(*) FROM t_order_count WHERE status = 1;
```

InnoDB 的 `COUNT(*)` 需要实际扫描索引或数据行计数（不像 MyISAM 有元数据计数），50 万行扫描很慢。

## 优化方案

```sql
-- good.sql: 查预计算的汇总表
SELECT SUM(order_count) FROM t_order_daily_stats;
```

维护一张日汇总表，查询时直接读汇总表，O(1)。

<ExplainCompare
  :bad="{ type: 'ref/index', key: 'idx_status', rows: '500,000', Extra: '扫描全部匹配行计数' }"
  :good="{ type: 'index', key: 'PRIMARY', rows: '~730', Extra: '汇总表行数少' }"
  improvement="50万行扫描 -> 730行汇总，耗时下降 99%+"
/>

## 避坑指南

::: warning 注意事项
1. **汇总表维护**：用触发器、定时任务或应用层双写保持一致。
2. **近似值**：`SHOW TABLE STATUS` 的 `Rows` 是近似值，O(1) 但不精确。
3. **8.0 并行查询**：8.0.14+ 支持并行扫描，COUNT 有所提升，但不如汇总表。
:::

## 本地复现

```bash
./scripts/run-case.sh 20-count-optimization
```
