# 冷热数据分离

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['冷热分离', '分表', '归档', 'Buffer Pool']" />

## 90% 历史订单挤占 Buffer Pool：热冷分离
订单系统运行半年后，用户查"我的订单"越来越慢。表已经涨到千万级，90% 是历史订单，几乎没人看，但它们和热数据混在一张表里，把 Buffer Pool 挤得满满当当：

```sql
-- 查历史订单（模拟大表查询）
SELECT * FROM t_order_cold
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;
```

明明走了索引、只查 10 条，却要 **25ms**（冷缓存状态）。生产环境千万级表更是 **200ms+**。问题不在索引，而在冷数据把热数据挤出了缓存。

这就是 **"冷热数据混杂"** 的架构痛点--90% 的查询只看近期数据，但 90% 的存储被历史数据占据，热数据频繁被挤出 Buffer Pool，查询被迫走磁盘 I/O。

::: warning 真实场景
订单、流水、日志、消息记录--任何持续写入的业务表，时间一长都会面临冷热失衡。历史数据访问频率极低却占用大量存储和缓存，拖慢热查询。冷热分离是这类场景的标准架构方案。
:::

## 问题分析

### bad.sql

```sql
-- 查询冷表（模拟单表大表场景）：冷表 15 万行，数据量大、缓存命中率低
-- 生产环境中如果不分离，所有数据在一张大表里，热查询也会被冷数据拖慢
-- 这里直接查冷表模拟"大表查历史"的慢查询场景
SELECT * FROM t_order_cold
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;
```

### EXPLAIN 结果

```
+----+--------------+-------+-------------------+---------+------+------+----------+-----------------------+
| id | table        | type  | key               | key_len | ref  | rows | filtered | Extra                 |
+----+--------------+-------+-------------------+---------+------+------+----------+-----------------------+
|  1 | t_order_cold | ref   | idx_user_created  | 8       | const| 3    | 100.00   | Backward index scan   |
+----+--------------+-------+-------------------+---------+------+------+----------+-----------------------+
```

### 为什么慢

执行计划看似不错（走了索引、rows 很小），但问题在**数据访问层面**而非索引定位：

1. **冷表数据量大**：15 万行历史数据，总数据体积远超 Buffer Pool 热数据区
2. **缓存命中率低**：冷表数据很少被访问，大概率不在 Buffer Pool 中，需从磁盘读取
3. **磁盘随机 I/O**：回表聚簇索引读取行数据时，数据页大概率不在内存，触发磁盘随机读
4. **SELECT \* 回表**：需要读取完整行数据（order_no, amount, status 等），回表代价高
5. **大表索引维护开销**：如果不分离，热数据和冷数据混在一张大表，索引 B+ 树层级更深

生产环境的真实问题（本案例用 15 万行模拟，生产可达千万甚至亿级）：

```
不分离（单表 1000 万行）:
  - 索引 B+ 树 3-4 层，定位需多次磁盘 I/O
  - Buffer Pool 被冷数据占满，热数据频繁被挤出
  - 热查询也可能因缓存未命中而变慢
  - DDL（加索引等）在千万级表上耗时极长

分离后（热表 50 万 + 冷表 950 万）:
  - 热表索引 B+ 树仅 2-3 层，定位快
  - 热表数据完全驻留 Buffer Pool，查询零磁盘 I/O
  - 冷表可独立优化（如压缩存储、放到慢速磁盘）
```

::: tip 核心认知
EXPLAIN 看不出冷热问题--执行计划一模一样，rows 都很小。慢的根因是 Buffer Pool 命中率：冷数据不在内存，热数据被挤出内存。这是架构层面的问题，索引优化解决不了。
:::

## 优化方案

### good.sql

```sql
-- 冷热分离后查询热表：热表仅 5 万行，数据常驻 Buffer Pool 缓存
-- 绝大多数用户查询的是近期订单，直接命中热表，查询极快
-- 需要查历史时再查冷表，或用 UNION ALL 合并两表结果
SELECT * FROM t_order_hot
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;
```

### 表结构

热表和冷表同结构，按时间分离：

```sql
-- 热表: 近 3 个月订单（5 万行）
CREATE TABLE t_order_hot (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL,
    order_no     VARCHAR(32)   NOT NULL,
    amount       DECIMAL(10,2) NOT NULL,
    status       TINYINT       NOT NULL DEFAULT 0,
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB COMMENT='订单热表（近3个月）';

-- 冷表: 3 个月以上历史订单（15 万行，同结构）
CREATE TABLE t_order_cold (
    -- 字段与热表完全相同
    ...
    KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB COMMENT='订单冷表（3个月以上历史）';
```

### 原理

执行计划结构与 bad 方案相同（都是 ref + idx_user_created），性能差异来自**数据规模和缓存**：

1. **热表数据量小**：仅 5 万行，索引 B+ 树层级浅，定位更快
2. **全量驻留缓存**：5 万行热数据完全驻留 Buffer Pool，查询**零磁盘 I/O**
3. **索引也在缓存**：热表的索引页常驻内存，索引遍历无磁盘读
4. **回表也在缓存**：回表聚簇索引读行数据，数据页大概率在 Buffer Pool 中

冷热分离的核心价值：

```
分离前: 单表 1000 万行
  Buffer Pool (假设 2GB)
    -> 被冷热数据混合占据
    -> 热数据（近3月，约10%）被冷数据挤出
    -> 热查询缓存命中率低 -> 磁盘 I/O

分离后: 热表 100 万 + 冷表 900 万
  Buffer Pool (假设 2GB)
    -> 热表 100 万行完全驻留（约 200MB）
    -> 热查询缓存命中率 ~100% -> 零磁盘 I/O
    -> 冷表可独立放到低成本存储
```

### 需要查历史时：UNION ALL

```sql
-- 先查热表，不够再查冷表（应用层判断）
SELECT * FROM t_order_hot
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 10;

-- 如果热表结果不足 10 条，补充查冷表
SELECT * FROM (
    (SELECT * FROM t_order_hot WHERE user_id = 12345)
    UNION ALL
    (SELECT * FROM t_order_cold WHERE user_id = 12345)
) t
ORDER BY created_at DESC
LIMIT 10;
```

<ExplainCompare
  :bad="{ type: 'ref', key: 'idx_user_created', rows: '3', Extra: 'Backward index scan（冷表15万行，缓存未命中）' }"
  :good="{ type: 'ref', key: 'idx_user_created', rows: '2', Extra: 'Backward index scan（热表5万行，全量驻留缓存）' }"
  improvement="执行计划相同，但热表全量驻留 Buffer Pool，零磁盘 I/O，耗时下降约 8 倍"
/>

## 量化对比

| 指标 | bad (查冷表 15万行) | good (查热表 5万行) | 提升 |
|------|---------------------|---------------------|------|
| 表行数 | 150,000 | 50,000 | **缩小 3 倍** |
| 缓存命中率 | 低（冷数据） | ~100%（热数据） | **零磁盘 I/O** |
| 索引 B+ 树层级 | 3 层 | 2 层 | **减少 1 层** |
| 耗时 | ~25 ms | ~3 ms | **约 8 倍** |

> 生产环境千万级表对比更显著：单表热查询可能 200ms+，分离后热表查询 < 5ms。

## 避坑指南

::: warning 注意事项

1. **分离策略要匹配业务访问模式**：按时间是常见方案，也可按状态（活跃/归档）分离。

2. **归档任务要自动化**：定时将过期数据从热表迁移到冷表（INSERT INTO cold + DELETE FROM hot）。

3. **跨表查询要优雅降级**：先查热表，不足再查冷表，避免每次都 UNION ALL 两表。

4. **冷表可压缩存储**：使用 ROW_FORMAT=COMPRESSED 减少冷表磁盘占用。

5. **冷表可放慢速磁盘**：冷数据访问频率低，可放到 HDD 或对象存储，SSD 留给热表。

6. **考虑分区表作为替代**：如果不方便分表，可用 MySQL 分区表（PARTITION BY RANGE）实现逻辑分离。

7. **注意自增 ID 冲突**：分表后各表独立自增，跨表查询需用 created_at 排序而非 id。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 冷热分离方案 | ✅ 有效 | ✅ 有效 |
| 降序索引扫描 | Using filesort | Backward index scan |
| 分区表 | ✅ 支持 | ✅ 支持 |
| 核心价值 | 架构层面数据分离 | 架构层面数据分离 |

::: tip 8.0 Backward index scan
执行计划结构在两个版本上一致，冷热分离方案与版本无关，核心价值在于架构层面的数据分离。

差异仅在 EXPLAIN 的 Extra 显示：8.0 对 `ORDER BY ... DESC` 显示 `Backward index scan`（逆向索引扫描，无需排序）；5.7 无降序索引优化，显示 `Using filesort`。这只影响排序步骤，不影响冷热分离的核心收益。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 54-hot-cold-separation

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 54-hot-cold-separation --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 54-hot-cold-separation --no-seed
```
