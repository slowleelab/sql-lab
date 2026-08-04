# 大表 DELETE 分批

<CaseMeta difficulty="⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['大表DELETE', '分批', '大事务', '主从延迟', 'binlog']" />

## 70% 是 DEBUG 日志：一条 DELETE 引发的灾难
日志表堆积了大量 DEBUG 级别数据，占了 70% 的空间。运维同学写了一条清理语句，想着一把删干净：

```sql
DELETE FROM t_log WHERE level = 0;
```

20 万行表里约 14 万行是 DEBUG，这条语句执行了 **2 秒**。更严重的是，执行期间所有对日志表的写入全部超时，从库延迟从 0 飙到 **40 秒**。

这就是 **"大事务 DELETE"** 事故--一次性删除大量数据，产生超大事务、长时间持锁、binlog 单条体积巨大，把主从延迟和业务可用性一起拖下水。

::: warning 真实场景
日志清理、过期数据归档、订单软删转硬删、临时表清空--凡是需要批量删除大量行的场景，都可能踩到这个坑。表越大、删除行数越多，问题越严重。
:::

## 问题分析

### bad.sql

```sql
-- 一次性删除所有 DEBUG 日志（大事务，锁表，主从延迟）
-- 20 万行中约 70% 是 DEBUG，即约 14 万行一次性删除
-- 问题: 单条 DELETE 产生超大事务，长时间持有行锁，binlog 单条体积巨大
DELETE FROM t_log WHERE level = 0;
```

### EXPLAIN 结果

```
-- EXPLAIN DELETE
+----+--------+--------+-------+----------------------+---------+--------+----------+-------------+
| id | table  | type   | key   | key_len              | ref     | rows   | filtered | Extra       |
+----+--------+--------+-------+----------------------+---------+--------+----------+-------------+
|  1 | t_log  | range  | idx_level_created| 1        | NULL    | 139580 | 100.00   | Using where |
+----+--------+--------+-------+----------------------+---------+--------+----------+-------------+
```

执行计划走了索引（`type=range`，`key=idx_level_created`），数据定位没问题。**问题不在找到数据，而在删除时的行为。**

### 为什么慢

| 维度 | bad（一次性 14 万行） | 影响 |
|------|---------------------|------|
| 事务大小 | 单条巨型事务 | undo log 暴涨 |
| 行锁持有 | 全程（整个事务期间） | 阻塞其他事务写入 |
| binlog 体积 | 14 万行记入单条 event | 从库单线程回放极慢 |
| 主从延迟 | 数十秒~分钟 | 数据严重滞后 |
| Buffer Pool | 大量页被加载 | 热数据被挤出 |

大事务的危害链：

```
14万行 DELETE
  -> 单条巨型事务
    -> undo log 暴涨
    -> 长时间行锁
    -> binlog 单条体积巨大
      -> 从库单线程回放慢
      -> 主从延迟数十秒~分钟
```

1. **大事务**：14 万行删除在一个事务内完成，undo log 体积巨大
2. **长时间持锁**：所有被删行的行锁在整个事务期间持有，阻塞其他事务的写入
3. **binlog 膨胀**：14 万行删除全部记录在**单条 binlog event** 中，从库单线程回放极慢
4. **主从延迟**：从库回放这条巨型事务可能需要数十秒甚至数分钟，期间数据严重滞后
5. **Buffer Pool 污染**：大量数据页被加载到 Buffer Pool，挤掉热数据
6. **回滚风险**：如果中途失败，14 万行的 undo 回滚可能比删除本身还慢

::: tip 核心认知
DELETE 的代价不只是"删多少行"，而是"这个事务有多大"。大事务的危害是连锁的：锁 -> binlog -> 主从延迟 -> 回滚风险。分批的本质是把一个大事务拆成无数个小事务。
:::

## 优化方案

### good.sql

```sql
-- 分批删除：每次只删 1000 行，避免大事务
-- 生产中用脚本/程序循环执行此语句，直到 affected_rows = 0 停止：
--   while true:
--     execute "DELETE FROM t_log WHERE level=0 LIMIT 1000"
--     if affected_rows == 0: break
--     sleep 0.1s  -- 适当停顿，给主从同步留出窗口
DELETE FROM t_log WHERE level = 0 LIMIT 1000;
```

### 原理

单次执行耗时极短（约 5-10 ms），关键在于**每次只删一小批**：

1. **小事务**：每次只删 1000 行，undo log 体积可控，事务瞬间提交
2. **短锁持有**：行锁持有时间从"全程"降到毫秒级，其他事务几乎不阻塞
3. **binlog 粒度小**：每批 1000 行是独立的 binlog event，从库可并行回放
4. **主从延迟可控**：批次间适当 sleep，从库有时间追赶，延迟保持低位
5. **可中断恢复**：中途失败只需从上次断点继续，不影响已删除的数据

### 完整分批删除脚本

good.sql 展示的是单次删除，生产中用程序循环执行：

```python
# Python 示例
while True:
    affected = execute("DELETE FROM t_log WHERE level=0 LIMIT 1000")
    if affected == 0:
        break
    sleep(0.1)  # 适当停顿，给主从同步留出窗口
```

```bash
# Shell 示例
while true; do
  ROWS=$(mysql -e "DELETE FROM t_log WHERE level=0 LIMIT 1000; SELECT ROW_COUNT();" | tail -1)
  [ "$ROWS" -eq 0 ] && break
  sleep 0.1
done
```

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_level_created', rows: '139,580', Extra: '单事务删14万行，长锁+大binlog' }"
  :good="{ type: 'range', key: 'idx_level_created', rows: '1,000', Extra: '小事务，毫秒级锁，binlog粒度小' }"
  improvement="单次锁持有从秒级降到毫秒级，binlog 体积减少 99%，主从延迟可控"
/>

## 量化对比

| 指标 | bad (一次性 14万行) | good (分批 1000行/次) | 提升 |
|------|---------------------|----------------------|------|
| 单次锁持有时间 | 800ms - 2s | 5-10 ms | **约 100 倍** |
| 单条 binlog 体积 | ~140MB | ~1MB | **减少 99%** |
| 主从延迟 | 数十秒~分钟 | <1 秒 | **可控** |
| 事务可中断 | 否（回滚极慢） | 是（断点续删） | **可恢复** |
| Buffer Pool 影响 | 严重污染 | 轻微 | **热数据不被挤出** |

## 避坑指南

::: warning 注意事项

1. **分批大小要适中**：太小则循环次数多开销大，太大则失去分批意义。推荐 500-5000 行/批。

2. **批次间适当 sleep**：避免连续删除压垮从库，sleep 时间根据从库延迟动态调整。

3. **监控从库延迟**：用 `SHOW SLAVE STATUS` 的 `Seconds_Behind_Master` 动态调节 sleep。

4. **走索引删除**：WHERE 条件必须命中索引，否则 LIMIT 仍需全表扫描找行。

5. **优先考虑分区表**：如果按时间清理，用 `ALTER TABLE ... DROP PARTITION` 比 DELETE 更高效，直接丢弃分区文件，不产生 binlog 删除事件。

6. **注意 LIMIT 无 ORDER BY 的不确定性**：如需确定顺序，加 `ORDER BY id LIMIT 1000`。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 分批 DELETE 方案 | ✅ 有效 | ✅ 有效 |
| 从库并行回放 (MTS) | 支持，效率略低 | 更高效，并行度更高 |
| 大事务影响 | 更严重（回放慢） | 略好（并行回放） |
| 分批后效果 | 小事务高效回放 | 小事务高效回放 |

::: tip 8.0 并行回放
8.0 的多线程从库回放（MTS）效率更高，但**大事务仍会降低并行度**--单条巨型 binlog event 只能单线程回放。分批后每批是小事务，5.7 和 8.0 都能高效并行回放，这才是分批的真正价值。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 44-batch-delete

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 44-batch-delete --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 44-batch-delete --no-seed
```
