# OPTIMIZE TABLE 碎片整理

<CaseMeta difficulty="⭐⭐" category="DDL与大表" versions="5.7 & 8.0" :tags="['碎片整理', 'OPTIMIZE TABLE', '空间回收', 'DELETE后']" />

## 删掉 70% 数据磁盘没降：表碎片空洞 6.8MB
订单表 `t_fragment_order` 插入 20 万行后，运维清理了 70% 的无效数据（status 为待付/发货/已取消的订单）。DELETE 完成后，表只剩 6 万行有效数据，但磁盘空间几乎没降--ibd 文件依然占着 14MB，其中 6.8MB 是碎片空洞。查询也变慢了：

```sql
-- 查看碎片状态
SELECT
    table_name, table_rows,
    ROUND(data_length / 1024 / 1024, 2)  AS data_mb,
    ROUND(index_length / 1024 / 1024, 2) AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)    AS free_mb
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';

-- 查询碎片表的效率（扫描包含空洞的数据页）
SELECT user_id, COUNT(*) AS order_cnt, SUM(amount) AS total_amount
FROM t_fragment_order
WHERE status = 1
GROUP BY user_id
ORDER BY total_amount DESC
LIMIT 20;
```

DELETE 前 20 万行时 `data_mb` 约 18.5MB，DELETE 70% 后 `data_mb` 仅降到 14.2MB，而 `free_mb` 高达 6.8MB--28% 的表空间是碎片。

::: warning 真实场景
日志清理、订单软删转硬删、过期数据归档--大量 DELETE 后，InnoDB 只标记行为"已删除"，不释放物理页空间给操作系统。碎片累积导致磁盘虚占、查询变慢、buffer pool 浪费。这是大表运维的经典痛点。
:::

## 问题分析

### bad.sql

```sql
-- 查询碎片表（DELETE 后未优化）
--
-- 1. t_fragment_order 插入 20 万行后 DELETE 了 70%（约 14 万行）
-- 2. InnoDB DELETE 只标记行为"已删除"，不释放物理页空间给操作系统
-- 3. 表的 DATA_FREE 较大（碎片空间），DATA_LENGTH 仍按原大小计算
-- 4. 查询时仍需扫描包含"空洞"的数据页，I/O 效率下降
-- 5. 索引 B+ 树也存在碎片，扫描效率降低

-- 查看碎片状态:
SELECT
    table_name,
    table_rows                                          AS rows_count,
    ROUND(data_length / 1024 / 1024, 2)                 AS data_mb,
    ROUND(index_length / 1024 / 1024, 2)                AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)                   AS free_mb,
    ROUND(data_free / (data_length + index_length) * 100, 2) AS free_pct
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';

-- 查询碎片表的效率（扫描包含空洞的数据页）:
SELECT
    user_id, COUNT(*) AS order_cnt, SUM(amount) AS total_amount
FROM t_fragment_order
WHERE status = 1
GROUP BY user_id
ORDER BY total_amount DESC
LIMIT 20;
```

### 表空间碎片状态

| table_name | table_rows | data_mb | index_mb | free_mb |
|-----------|-----------|---------|----------|---------|
| t_fragment_order | ~60,000 | 14.2 | 9.8 | **6.8** |

（DELETE 前 20 万行时 data_mb 约 18.5，DELETE 70% 后 data_mb 仅降到 14.2，因为被删行的空间未释放）

### EXPLAIN 结果

```
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
| id | select_type | table             | partitions | type | possible_keys          | key                    | key_len | ref   | rows   | filtered | Extra       |
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
|  1 | SIMPLE      | t_fragment_order  | NULL       | ref  | idx_status_created     | idx_status_created     | 1       | const |  29840 |   100.00 | Using where |
+----+-------------+-------------------+------------+------+------------------------+------------------------+---------+-------+--------+----------+-------------+
```

EXPLAIN ANALYZE（8.0 扩展）显示 cost=12042：

```
-> Limit: 20 row(s)  (cost=12042 rows=20)
    -> Sort: total_amount DESC, limit input to 20 row(s) per chunk  (cost=12042 rows=20)
        -> Stream results  (cost=12042 rows=20)
            -> Group aggregate: max(amount), count(*), sum(amount)  (cost=12042 rows=29840)
                -> Index lookup on t_fragment_order using idx_status_created (status=1)  (cost=12042 rows=29840)
```

| 指标 | 值 | 分析 |
|------|-----|------|
| table_rows | ~60,000 | DELETE 后仅剩 6 万行 |
| data_mb | 14.2 | **仍占 14.2MB（DELETE 前 18.5MB，仅降 23%）** |
| free_mb | **6.8** | **碎片空间 6.8MB 未释放** |
| free_pct | ~28% | **28% 的表空间是碎片** |
| rows (EXPLAIN) | ~29,840 | status=1 约 3 万行 |
| 实际扫描页 | 含空洞 | 数据页中 70% 是已删行的"空洞" |

### 为什么慢

DELETE 14 万行后，InnoDB 的行为：

1. **标记删除不释放页**：InnoDB DELETE 只在记录头打删除标记，数据页不立即归还操作系统
2. **DATA_FREE 累积**：被删行的空间成为 `DATA_FREE`（碎片空间），6.8MB 空间被标记为可重用但未释放
3. **DATA_LENGTH 虚高**：表仍占用 14.2MB 数据空间，而实际有效数据只有约 4MB（6万行），大量空间是空洞
4. **扫描效率下降**：查询 status=1 的行时，需扫描包含 70% 空洞的数据页，每个数据页有效行数少，相同结果需要扫描更多页
5. **buffer pool 浪费**：空洞页占据 buffer pool，挤掉有效热数据

**实际影响**：查询需扫描约 **900 个数据页**（含空洞），而整理后只需约 250 页。

::: tip 核心认知
InnoDB DELETE 不释放物理空间，只打删除标记。碎片率（`DATA_FREE / (DATA_LENGTH + INDEX_LENGTH)`）超过 20% 时，查询要扫描大量空洞页，I/O 效率下降。OPTIMIZE TABLE 重建表回收碎片，是 DELETE 后的必要维护。
:::

## 优化方案

### setup-good.sql（前置准备）

执行 good.sql 前，需要先执行 `setup-good.sql` 进行碎片整理（OPTIMIZE TABLE 等价于 `ALTER TABLE ... ENGINE=InnoDB` + `ANALYZE TABLE`）：

```sql
-- 执行 OPTIMIZE TABLE 重建表回收碎片
-- 8.0 中使用 ALGORITHM=COPY:
--   1. 创建临时表（.ibd 文件）
--   2. 逐行复制存活数据到新表
--   3. RENAME 替换旧表
--   4. DROP 旧表及其 ibd 文件
--   5. 更新统计信息
--
-- 执行前请确认:
--   - 低峰期执行（MDL 锁会阻塞写入）
--   - 磁盘空间充足（需要原表大小的临时空间）

OPTIMIZE TABLE t_fragment_order;

-- 等效写法（8.0 推荐，语义更清晰）:
-- ALTER TABLE t_fragment_order ENGINE=InnoDB, ALGORITHM=COPY, LOCK=SHARED;
```

### good.sql

```sql
-- 执行 OPTIMIZE TABLE 后查询（碎片已整理）
--
-- 1. OPTIMIZE TABLE 重建表:
--    - 8.0: 使用 inplace 重建（ALGORITHM=COPY）
--      实际是 CREATE 新表 -> 复制数据 -> RENAME -> DROP 旧表
--    - 5.7: 使用 COPY 方式重建
-- 2. 重建后:
--    - DATA_FREE 大幅降低（碎片空间被回收）
--    - DATA_LENGTH 降低（紧凑存储，无空洞）
--    - 索引 B+ 树重新组织，扫描效率提升
-- 3. 物理空间释放给操作系统（ibd 文件缩小）

-- 查看碎片整理后的状态（DATA_FREE 和 DATA_LENGTH 应显著降低）:
SELECT
    table_name,
    table_rows                                          AS rows_count,
    ROUND(data_length / 1024 / 1024, 2)                 AS data_mb,
    ROUND(index_length / 1024 / 1024, 2)                AS index_mb,
    ROUND(data_free / 1024 / 1024, 2)                   AS free_mb,
    ROUND(data_free / (data_length + index_length) * 100, 2) AS free_pct
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 't_fragment_order';

-- 查询碎片整理后的效率（数据页紧凑，I/O 减少）:
SELECT
    user_id, COUNT(*) AS order_cnt, SUM(amount) AS total_amount
FROM t_fragment_order
WHERE status = 1
GROUP BY user_id
ORDER BY total_amount DESC
LIMIT 20;
```

### 原理

OPTIMIZE TABLE 重建表后的变化：

1. **物理空间回收**：`DATA_LENGTH` 从 14.2MB 降到 4.5MB，ibd 文件缩小，释放 9.7MB 给操作系统
2. **碎片消除**：`DATA_FREE` 从 6.8MB 降到 0.2MB，被删行的空洞被完全消除
3. **数据页紧凑**：存活行重新紧凑排列，每个数据页填充率高，扫描同样行数需要更少的页
4. **索引重组**：B+ 树重新构建，节点填充率高，索引扫描 I/O 减少
5. **统计信息更新**：OPTIMIZE TABLE 同时更新统计信息（ANALYZE），优化器估算更准确
6. **buffer pool 利用率提升**：紧凑的数据页让 buffer pool 容纳更多有效数据

### 对比

| | bad.sql (碎片表) | good.sql (整理后) |
|---|---|---|
| 查询耗时 | ~340 ms | **~130 ms** |
| DATA_LENGTH | 14.2 MB | **4.5 MB** |
| INDEX_LENGTH | 9.8 MB | **3.1 MB** |
| DATA_FREE | 6.8 MB | **0.2 MB** |
| 碎片率 | 28% | **2.6%** |
| 扫描数据页 | ~900 | **~250** |
| EXPLAIN cost | 12042 | **3812** |

整理后表空间碎片状态：

| table_name | table_rows | data_mb | index_mb | free_mb |
|-----------|-----------|---------|----------|---------|
| t_fragment_order | ~60,000 | **4.5** | **3.1** | **0.2** |

EXPLAIN ANALYZE（8.0 扩展）显示 cost 从 12042 降到 3812：

```
-> Limit: 20 row(s)  (cost=3812 rows=20)
    -> Sort: total_amount DESC, limit input to 20 row(s) per chunk  (cost=3812 rows=20)
        -> Stream results  (cost=3812 rows=20)
            -> Group aggregate: max(amount), count(*), sum(amount)  (cost=3812 rows=29840)
                -> Index lookup on t_fragment_order using idx_status_created (status=1)  (cost=3812 rows=29840)
```

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_status_created', rows: '29,840', Extra: '碎片率28%，扫描900页，cost=12042' }"
  :good="{ type: 'ref', key: 'idx_status_created', rows: '29,840', Extra: '碎片率2.6%，扫描250页，cost=3812' }"
  improvement="DATA_FREE 消除 97%，扫描数据页从 900 降到 250，耗时下降约 2.6 倍"
/>

## 避坑指南

::: warning 注意事项

1. **监控碎片率**。定期查询 `information_schema.tables` 的 `DATA_FREE / (DATA_LENGTH + INDEX_LENGTH)`，超过 20% 考虑整理。

2. **低峰期执行 OPTIMIZE TABLE**。OPTIMIZE TABLE 期间表不可写（8.0 可读不可写，5.7 完全锁定），需在业务低峰期执行。大表用 `pt-online-schema-change` 等在线 DDL 工具可在不停服的情况下重建表。

3. **确保磁盘空间充足**。重建需要原表大小的临时空间，磁盘不足会导致失败。

4. **优先用分区表 DROP PARTITION**。按时间清理的数据用分区表，`DROP PARTITION` 瞬间完成且不产生碎片，从源头避免碎片问题。

5. **8.0 可用 ALTER TABLE 替代**。`ALTER TABLE ... ENGINE=InnoDB` 与 OPTIMIZE TABLE 等效，语义更清晰。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| OPTIMIZE TABLE 算法 | COPY（重建表） | COPY（重建表） |
| 锁定行为 | 表级锁，不可读写 | MDL 锁，不可写（可读） |
| EXPLAIN ANALYZE | ❌ 不支持 | ✅ 支持行级执行统计和 cost |
| 重建效果 | 一致 | 一致 |

::: tip 8.0 在线支持
8.0 的 OPTIMIZE TABLE 使用 `ALGORITHM=COPY`，期间允许读操作（SHARED 锁），但不允许写。5.7 期间表完全锁定。两版本都会重建表和索引，效果一致。大表建议用 `pt-online-schema-change` 避免长时间锁表。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 47-optimize-table-fragmentation

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 47-optimize-table-fragmentation --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 47-optimize-table-fragmentation --no-seed
```
