# EXPLAIN 参考结果 - good.sql (查汇总表)

## MySQL 8.0（汇总表 t_daily_summary，约 365 行）

```
+----+-------------+-----------------+------------+-------+---------------+---------+---------+------+------+----------+----------------+
| id | select_type | table           | partitions | type  | possible_keys | key     | key_len | ref  | rows | filtered | Extra          |
+----+-------------+-----------------+------------+-------+---------------+---------+---------+------+------+----------+----------------+
|  1 | SIMPLE      | t_daily_summary | NULL       | range | PRIMARY       | PRIMARY | 3       | NULL |  195 |   100.00 | Using where    |
+----+-------------+-----------------+------------+-------+---------------+---------+---------+------+------+----------+----------------+
```

## 关键改进

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | **主键范围扫描** |
| key | `PRIMARY` | 走主键索引（stat_date） |
| rows | ~195 | **仅需扫描约 195 行**（半年数据，1行/天） |
| Extra | `Using where` | 无临时表、无文件排序 |

## 为什么快

汇总表 `t_daily_summary` 将聚合计算前置到离线阶段：

1. **数据量降 3 个数量级**：从 30 万行明细降到 365 行汇总（1 行/天）
2. **主键范围扫描**：stat_date 是主键，WHERE stat_date >= '2026-01-01' 走主键高效定位
3. **零聚合计算**：order_count 和 total_amount 已预计算，直接读取
4. **无临时表**：不需要 GROUP BY，没有 Using temporary
5. **无文件排序**：主键本身有序，ORDER BY stat_date 直接利用主键有序性

### 汇总表的维护方式

```sql
-- 方式1: 定时全量刷新（每天凌晨执行）
TRUNCATE TABLE t_daily_summary;
INSERT INTO t_daily_summary (stat_date, order_count, total_amount)
SELECT DATE(created_at), COUNT(*), SUM(amount)
FROM t_order_report
GROUP BY DATE(created_at);

-- 方式2: 增量更新（更推荐，只更新当天）
INSERT INTO t_daily_summary (stat_date, order_count, total_amount)
SELECT DATE(created_at), COUNT(*), SUM(amount)
FROM t_order_report
WHERE DATE(created_at) = CURDATE()
GROUP BY DATE(created_at)
ON DUPLICATE KEY UPDATE
    order_count = VALUES(order_count),
    total_amount = VALUES(total_amount);
```

## 量化对比

| 指标 | bad (实时聚合) | good (汇总表) | 提升 |
|------|---------------|---------------|------|
| 扫描行数 | ~148,679 | ~195 | **约 760 倍** |
| 临时表 | Using temporary | 无 | **消除** |
| 文件排序 | Using filesort | 无 | **消除** |
| 聚合计算 | 15 万行 SUM/COUNT | 零（预计算） | **消除** |
| 耗时 | ~350 ms | ~2 ms | **约 175 倍** |

## 5.7 vs 8.0 差异

- 执行计划结构一致，汇总表方案在两个版本上都有效
- 8.0 的 temptable 引擎让 bad 方案的临时表性能略好，但无法从根本上解决扫描开销
- 汇总表方案与版本无关，核心是架构层面的预计算

## 避坑指南

1. **汇总表适合读多写少的报表场景**：如果数据频繁变更且需实时一致，汇总表维护成本高
2. **选择合适的聚合粒度**：按天/小时/分钟，粒度越细行数越多，按业务需求权衡
3. **增量更新优于全量刷新**：用 ON DUPLICATE KEY UPDATE 只刷新当天数据，减少刷新开销
4. **注意数据一致性窗口**：汇总表有延迟（如 T+1），实时性要求高的场景需配合实时修正
5. **多维汇总考虑物化视图**：如果需要按多个维度（日期+用户+类目）汇总，考虑预计算多个汇总表
6. **监控汇总表更新任务**：定时任务失败会导致报表数据过期，需告警监控
