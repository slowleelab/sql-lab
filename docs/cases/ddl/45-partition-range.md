# 分区表 RANGE 分区优化

<CaseMeta difficulty="⭐⭐⭐" category="DDL与大表" versions="5.7 & 8.0" :tags="['分区表', 'RANGE分区', '分区裁剪', '大表优化']" />

## 场景痛点

日志系统的 `t_partition_log` 表堆积了 96 万行数据（12 个月），查询某月日志时，虽然走了 `idx_created` 索引，却仍要扫描跨越全部 12 个月数据的索引树：

```sql
SELECT id, user_id, log_level, message, created_at
FROM t_partition_log
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-01-31 23:59:59'
ORDER BY created_at DESC
LIMIT 100;
```

更头疼的是，清理历史数据只能用 `DELETE FROM t_partition_log WHERE created_at < '2024-01-01'`，大事务、锁表、主从延迟一条龙。随着数据增长到千万、亿级，普通表的索引膨胀和数据混杂问题会急剧放大。

::: warning 真实场景
日志表、流水表、埋点表--凡是按时间写入、按时间查询、按时间清理的大表，都是 RANGE 分区的理想场景。分区裁剪让查询只扫目标分区，`DROP PARTITION` 让历史清理瞬间完成。
:::

## 问题分析

### bad.sql

```sql
-- 普通表查询某月数据（全表扫描）
--
-- 1. 普通表 t_partition_log 无分区，96 万行数据存储在单一表空间
-- 2. 查询 created_at BETWEEN '2024-01-01' AND '2024-01-31'
--    虽然走 idx_created 索引，但索引跨越全部 96 万行
-- 3. 无分区裁剪：优化器无法排除其他月份数据的索引范围
-- 4. EXPLAIN 的 partitions 列为 NULL（无分区）
SELECT
    id, user_id, log_level, message, created_at
FROM t_partition_log
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-01-31 23:59:59'
ORDER BY created_at DESC
LIMIT 100;
```

### EXPLAIN 结果

```
+----+-------------+------------------+------------+-------+---------------+-------------+---------+------+--------+----------+-------------+
| id | select_type | table            | partitions | type  | possible_keys | key         | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+------------------+------------+-------+---------------+-------------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | t_partition_log  | NULL       | range | idx_created   | idx_created | 6       | NULL |  78520 |   100.00 | Using where |
+----+-------------+------------------+------------+-------+---------------+-------------+---------+------+--------+----------+-------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| partitions | `NULL` | **无分区，无法裁剪** |
| type | `range` | 走 idx_created 索引范围扫描 |
| key | `idx_created` | 用了 created_at 索引 |
| rows | ~78,520 | 预估扫描约 7.8 万行（1月数据） |
| Extra | `Using where` | 索引范围扫描后过滤 |

### 为什么慢

表面上看走了索引范围扫描，rows 也只有约 7.8 万行，似乎不差。但问题在于：

1. **索引跨越全表**：`idx_created` 索引 B+ 树包含全部 96 万行的 created_at，索引本身很大
2. **无分区隔离**：查询 1 月数据时，索引树的根节点和中间节点要覆盖 12 个月范围，索引高度可能更高
3. **数据无物理隔离**：1 月数据与其他月份数据混在同一表空间，buffer pool 命中率低
4. **无分区裁剪**：`partitions` 列为 NULL，优化器无法跳过其他 11 个月的数据

**更关键的是管理成本**：
- 清理历史数据只能用 `DELETE FROM ... WHERE created_at < ...`，大事务
- 无法快速删除整个月数据
- 表越大，DDL 操作（加索引、修改结构）越慢

::: tip 核心认知
分区表的核心价值不只是查询加速，更是**物理隔离 + 管理便捷**：每个分区有独立的索引 B+ 树和数据页，分区裁剪跳过无关分区，`DROP PARTITION` 瞬间清理历史数据。
:::

## 优化方案

### setup-good.sql（前置准备）

执行 good.sql 前，需要先执行 `setup-good.sql` 创建按月 RANGE 分区表（分区表的主键必须包含分区键）：

```sql
DROP TABLE IF EXISTS t_partition_log;

CREATE TABLE t_partition_log (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL              COMMENT '用户ID',
    log_level    TINYINT       NOT NULL DEFAULT 0    COMMENT '日志级别: 0=DEBUG 1=INFO 2=WARN 3=ERROR',
    message      VARCHAR(500)  NOT NULL              COMMENT '日志内容',
    created_at   DATETIME      NOT NULL              COMMENT '日志时间',
    PRIMARY KEY (id, created_at),
    KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='日志表(按月RANGE分区)'
PARTITION BY RANGE (TO_DAYS(created_at)) (
    PARTITION p202401 VALUES LESS THAN (TO_DAYS('2024-02-01')),
    PARTITION p202402 VALUES LESS THAN (TO_DAYS('2024-03-01')),
    PARTITION p202403 VALUES LESS THAN (TO_DAYS('2024-04-01')),
    PARTITION p202404 VALUES LESS THAN (TO_DAYS('2024-05-01')),
    PARTITION p202405 VALUES LESS THAN (TO_DAYS('2024-06-01')),
    PARTITION p202406 VALUES LESS THAN (TO_DAYS('2024-07-01')),
    PARTITION p202407 VALUES LESS THAN (TO_DAYS('2024-08-01')),
    PARTITION p202408 VALUES LESS THAN (TO_DAYS('2024-09-01')),
    PARTITION p202409 VALUES LESS THAN (TO_DAYS('2024-10-01')),
    PARTITION p202410 VALUES LESS THAN (TO_DAYS('2024-11-01')),
    PARTITION p202411 VALUES LESS THAN (TO_DAYS('2024-12-01')),
    PARTITION p202412 VALUES LESS THAN (TO_DAYS('2025-01-01')),
    PARTITION pmax    VALUES LESS THAN MAXVALUE
);
```

> 注意：执行此 DDL 后，需重新运行 `seed.sql` 填充分区表数据，然后执行 good.sql 对比分区裁剪效果。

### good.sql

```sql
-- 分区表查询某月数据（分区裁剪）
--
-- 1. 分区表 t_partition_log 按 created_at 月度 RANGE 分区
-- 2. 查询 created_at BETWEEN '2024-01-01' AND '2024-01-31'
--    优化器执行分区裁剪(pruning)，只访问 p202401 分区
-- 3. EXPLAIN 的 partitions 列显示 p202401，而非全部 12 个分区
-- 4. 扫描范围从 96 万行降到 8 万行，索引也更紧凑
SELECT
    id, user_id, log_level, message, created_at
FROM t_partition_log
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-01-31 23:59:59'
ORDER BY created_at DESC
LIMIT 100;
```

### 原理

1. **分区裁剪**：优化器根据 `created_at BETWEEN '2024-01-01' AND '2024-01-31'` 判断只需访问 `p202401` 分区，跳过其他 11 个分区
2. **索引物理隔离**：每个分区有独立的索引 B+ 树，`p202401` 的 `idx_created` 只含 8 万行，索引更紧凑，树高更低
3. **数据物理隔离**：1 月数据集中在 `p202401` 分区的数据页中，buffer pool 局部性好
4. **EXPLAIN 直接可见**：`partitions` 列从 `NULL` 变为 `p202401`，裁剪效果一目了然

**管理成本优势**：清理 1 月数据用 `ALTER TABLE t_partition_log DROP PARTITION p202401`（瞬间完成，无大事务），各分区可独立维护。

### 对比

| | bad.sql (普通表) | good.sql (分区表) |
|---|---|---|
| 耗时 | ~180 ms | **~95 ms** |
| partitions 列 | NULL | **p202401** |
| 扫描分区数 | 1（全表） | **1（仅 p202401）** |
| 索引树高度 | 较高(96万行) | 较低(8万行) |
| 历史数据清理 | DELETE(大事务) | DROP PARTITION(瞬间) |

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_created', rows: '78,520', partitions: 'NULL (无分区裁剪)' }"
  :good="{ type: 'range', key: 'idx_created', rows: '78,520', partitions: 'p202401 (分区裁剪)' }"
  improvement="分区裁剪生效，只访问目标分区，耗时下降约 1.9 倍，历史清理从大事务变为瞬间操作"
/>

## 避坑指南

::: warning 注意事项

1. **分区键必须包含在主键/唯一键中**。分区表要求 `PRIMARY KEY (id, created_at)`，分区键 `created_at` 必须是主键的一部分。这是 MySQL 的硬性约束，否则建表报错。

2. **分区裁剪依赖 WHERE 条件包含分区键**。如果查询没有 `created_at` 的范围条件，优化器无法裁剪，会扫描全部分区（比普通表更慢）。且不能对分区键施加函数（除非用 `TO_DAYS` 等与分区函数一致的表达式）。

3. **分区数不宜过多**。建议 < 1000 个分区，过多分区会增加元数据管理开销，优化器在分区裁剪判断上也会变慢。

4. **清理历史数据优先用 DROP PARTITION**。`DROP PARTITION` 直接丢弃分区文件，不产生 binlog 删除事件，不产生碎片，瞬间完成。比 `DELETE` 高效数个数量级。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| RANGE 分区 + 分区裁剪 | ✅ 支持 | ✅ 支持 |
| 分区裁剪优化器 | 基础 | 更智能（函数表达式判断更准） |
| 分区维护 DDL | ALGORITHM=INPLACE | 支持，影响更小 |
| EXPLAIN ... PARTITIONS | ✅ 语法一致 | ✅ 语法一致 |

::: tip 8.0 分区优化
8.0 的分区裁剪优化器更智能，对函数表达式分区键的裁剪判断更准确，且支持 `ALGORITHM=INPLACE` 的分区维护操作，DDL 影响更小。但核心机制与 5.7 一致。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 45-partition-range

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 45-partition-range --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 45-partition-range --no-seed
```
