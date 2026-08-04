# 报表统计汇总表

<CaseMeta difficulty="⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['汇总表', '物化视图', '报表统计', '预聚合']" />

## 350ms 加载：日报聚合半年数据
运营后台的每日订单统计报表，加载需要 **350ms**。数据量不算夸张--30 万行订单明细表，查半年数据按天聚合：

```sql
SELECT DATE(created_at) AS d,
       COUNT(*) AS cnt,
       SUM(amount) AS total
FROM t_order_report
WHERE created_at >= '2026-01-01'
GROUP BY DATE(created_at)
ORDER BY d;
```

每次打开报表页都要等将近半秒，而且高峰期多个运营同时查看时更慢。报表数据其实每天才变一次，为什么要每次查询都实时算一遍？

这就是 **"大表实时聚合"** 的典型痛点--对明细表做 GROUP BY 聚合，数据量越大越慢，而报表场景的查询频率远高于数据变更频率，实时计算纯属浪费。

::: warning 真实场景
日活报表、销售日报、风控统计、财务对账--凡是按时间维度聚合统计的报表，只要明细表超过几十万行，实时 GROUP BY 就会成为性能瓶颈。报表读多写少的特性，天然适合预聚合。
:::

## 问题分析

### bad.sql

```sql
-- 实时聚合：对 30 万行明细表做 GROUP BY DATE(created_at)
-- 虽然有 idx_created 索引，但 GROUP BY DATE(created_at) 需要函数转换
-- MySQL 需扫描大量行做聚合计算，大表实时聚合耗时严重
SELECT DATE(created_at) AS d,
       COUNT(*) AS cnt,
       SUM(amount) AS total
FROM t_order_report
WHERE created_at >= '2026-01-01'
GROUP BY DATE(created_at)
ORDER BY d;
```

### EXPLAIN 结果

```
+----+-----------------+-------+---------------+---------+--------+----------+----------------------------------------------+
| id | table           | type  | key           | key_len | rows   | filtered | Extra                                        |
+----+-----------------+-------+---------------+---------+--------+----------+----------------------------------------------+
|  1 | t_order_report  | range | idx_created   | 5       | 148679 | 100.00   | Using index condition; Using temporary;      |
|    |                 |       |               |         |        |          | Using filesort                               |
+----+-----------------+-------+---------------+---------+--------+----------+----------------------------------------------+
```

### 为什么慢

对 30 万行明细表做 `GROUP BY DATE(created_at)` 的实时聚合：

1. **扫描大量行**：WHERE created_at >= '2026-01-01' 命中约 15 万行（半年数据）
2. **函数转换破坏索引有序性**：`DATE(created_at)` 是函数操作，无法直接利用 idx_created 的有序性做分组
3. **Using temporary**：MySQL 需要创建临时表来存储分组聚合的中间结果
4. **Using filesort**：GROUP BY 后的 ORDER BY 需要额外的排序步骤
5. **每行都要计算**：15 万行逐行计算 DATE() 函数 + SUM/COUNT 聚合，CPU 密集

实时聚合 vs 预聚合的对比：

```
实时聚合 (bad):
  查询时 -> 扫描 15万行 -> 逐行 DATE() -> 临时表分组 -> SUM/COUNT -> 排序 -> 返回
  每次查询都重复全量计算

预聚合 (good):
  定时任务 -> 每天增量更新汇总表（1行/天）
  查询时 -> 直接读汇总表（< 200行）-> 返回
  计算成本前置到离线，查询零计算
```

::: tip 核心认知
报表查询的本质是"读多写少"--数据一天变一次，查询一天执行几百次。把聚合计算从查询时挪到写入时（预聚合），用一次离线计算换无数次零计算查询。
:::

## 优化方案

### good.sql

```sql
-- 查询汇总表：数据已预聚合，直接按主键 stat_date 范围扫描
-- t_daily_summary 每天仅 1 行（365 行/年），查询毫秒级返回
-- 汇总表在生产中通过定时任务（如每天凌晨）增量更新
SELECT stat_date AS d,
       order_count AS cnt,
       total_amount AS total
FROM t_daily_summary
WHERE stat_date >= '2026-01-01'
ORDER BY stat_date;
```

### 表结构

汇总表 `t_daily_summary` 按天预聚合，每天仅 1 行：

```sql
CREATE TABLE t_daily_summary (
    stat_date     DATE           NOT NULL             COMMENT '统计日期',
    order_count   INT            NOT NULL DEFAULT 0   COMMENT '订单数',
    total_amount  DECIMAL(15,2)  NOT NULL DEFAULT 0   COMMENT '总金额',
    PRIMARY KEY (stat_date)
) ENGINE=InnoDB COMMENT='每日订单汇总表';
```

### 原理

汇总表将聚合计算前置到离线阶段：

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

::: tip 增量更新优于全量刷新
用 `ON DUPLICATE KEY UPDATE` 只刷新当天数据，减少刷新开销。当天数据可能多次更新（订单持续产生），定时任务可每小时刷新一次当天数据保证准实时。
:::

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_created', rows: '148,679', Extra: 'Using temporary; Using filesort' }"
  :good="{ type: 'range', key: 'PRIMARY', rows: '195', Extra: 'Using where' }"
  improvement="扫描行数从 15 万降到 195，消除临时表和文件排序，耗时下降约 175 倍"
/>

## 量化对比

| 指标 | bad (实时聚合) | good (汇总表) | 提升 |
|------|---------------|---------------|------|
| 扫描行数 | ~148,679 | ~195 | **约 760 倍** |
| 临时表 | Using temporary | 无 | **消除** |
| 文件排序 | Using filesort | 无 | **消除** |
| 聚合计算 | 15 万行 SUM/COUNT | 零（预计算） | **消除** |
| 耗时 | ~350 ms | ~2 ms | **约 175 倍** |

## 避坑指南

::: warning 注意事项

1. **汇总表适合读多写少的报表场景**：如果数据频繁变更且需实时一致，汇总表维护成本高。

2. **选择合适的聚合粒度**：按天/小时/分钟，粒度越细行数越多，按业务需求权衡。

3. **增量更新优于全量刷新**：用 ON DUPLICATE KEY UPDATE 只刷新当天数据，减少刷新开销。

4. **注意数据一致性窗口**：汇总表有延迟（如 T+1），实时性要求高的场景需配合实时修正。

5. **多维汇总考虑物化视图**：如果需要按多个维度（日期+用户+类目）汇总，考虑预计算多个汇总表。

6. **监控汇总表更新任务**：定时任务失败会导致报表数据过期，需告警监控。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 汇总表方案 | ✅ 有效 | ✅ 有效 |
| 临时表引擎 | MEMORY/MyISAM | temptable（默认） |
| bad 方案临时表性能 | 略差 | 略好 |
| 核心瓶颈 | 扫描+计算开销 | 扫描+计算开销 |

::: tip 8.0 temptable 引擎
执行计划结构在两个版本上一致，汇总表方案与版本无关，核心是架构层面的预计算。

差异在于：8.0 的 temptable 引擎让 bad 方案的临时表性能略好（支持更大的临时表且不占用 MyISAM 锁），但根本的扫描和计算开销无法消除。只有汇总表能从根上解决问题。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 53-summary-table

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 53-summary-table --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 53-summary-table --no-seed
```
