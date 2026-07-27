# 大批量 UPDATE 分批优化

<CaseMeta difficulty="⭐⭐" category="优化器" versions="5.7 & 8.0" :tags="['分批更新', '大批量UPDATE', '锁持有', '主从延迟']" />

## 场景痛点

运营发起批量操作："把半年前所有未支付订单标记为已过期"。一条 UPDATE 搞定？数据量 50 万行。执行后数据库 CPU 飙升、主从延迟 30 秒、大量业务请求锁等待超时。

```sql
-- 一次性 UPDATE 50 万行，锁持有时间过长
UPDATE t_order
SET status = 3
WHERE status = 2
  AND created_at < '2026-01-01';
```

::: warning 真实场景
任何需要批量修改大量行的操作（数据迁移、状态变更、过期清理）都可能踩坑。一次性 UPDATE 大量行会导致锁持有时间过长、undo log 膨胀、主从延迟加剧，是线上事故的常见诱因。
:::

## 问题分析

### bad.sql

```sql
UPDATE t_order
SET status = 3
WHERE status = 2
  AND created_at < '2026-01-01';
```

### EXPLAIN 结果

```
+----+-------------+---------+-------+--------------------+------------------+--------+----------+-------------+
| id | select_type | table   | type  | key                | key_len          | rows   | filtered | Extra       |
+----+-------------+---------+-------+--------------------+------------------+--------+----------+-------------+
|  1 | UPDATE      | t_order | range | idx_status_created | idx_status_created| 499830 |   100.00 | Using where |
+----+-------------+---------+-------+--------------------+------------------+--------+----------+-------------+
```

### 为什么慢

执行计划本身没问题（走了索引），**问题出在一次性更新 50 万行的锁和日志开销**：

1. **锁持有过久**：对 50 万行加 X 锁，整个事务持续 30 秒，并发事务大量阻塞
2. **undo log 膨胀**：生成 50 万条 undo log，MVCC 快照链过长， purge 线程无法清理
3. **主从延迟**：从库回放同样耗时 30 秒，读从库的业务读到旧数据
4. **可能触发超时**：`ERROR 1205: Lock wait timeout exceeded`

## 优化方案

### good.sql

```sql
-- 分批更新，每次 1000 行
UPDATE t_order
SET status = 3
WHERE status = 2
  AND created_at < '2026-01-01'
LIMIT 1000;

-- 重复执行直到 affected_rows = 0
-- 应用层伪代码:
--   do {
--       affected = execute("UPDATE ... LIMIT 1000");
--       sleep(10);  // 可选：短暂休眠
--   } while (affected > 0);
```

### 原理

分批更新的核心思想：**用多次小事务替代一次大事务**。

1. 每次 UPDATE 只更新 1000 行，锁持有时间从 30 秒降到 60ms
2. 每批提交后释放锁，undo log 及时 purge，不会膨胀
3. 主从延迟可控（每批在从库回放快，延迟 < 1 秒）
4. 并发事务几乎不会感知到锁等待
5. 批间可加入短暂休眠（如 10ms），进一步降低对线上业务的影响

### 对比

| | bad.sql（一次性） | good.sql（分批） |
|---|---|---|
| 每次更新行数 | ~500,000 | ~1,000 |
| 锁持有时间 | ~30 秒 | ~60 ms |
| undo log 累积 | 50 万条 | 1000 条/批 |
| 主从延迟 | +30 秒 | 几乎无影响 |
| 并发阻塞 | 严重 | 几乎无感知 |

<ExplainCompare
  :bad="{ type: 'range', key: 'idx_status_created', rows: '499,830', Extra: '一次性锁定 50 万行，30 秒长事务' }"
  :good="{ type: 'range', key: 'idx_status_created', rows: '499,830', Extra: '同样扫描但 LIMIT 1000 分批，每批 60ms' }"
  improvement="锁持有时间从 30 秒降到 60ms/批，主从延迟从 30 秒降到 <1 秒"
/>

## 避坑指南

::: warning 注意事项

1. **确保 WHERE 条件走索引**。本例依赖 `idx_status_created(status, created_at)` 索引。如果没有索引，每批 UPDATE 都全表扫描，分批反而更慢。

2. **LIMIT 大小的选择**。通常 500~5000 行/批。行越大（TEXT/BLOB）取小值，行越小取大值。观察锁等待和吞吐量调整。

3. **批间休眠**。高并发场景下加入 `sleep(10ms)` 给从库追赶时间，避免主从延迟累积。

4. **避免使用 ORDER BY**。`UPDATE ... ORDER BY id LIMIT 1000` 虽然可以保证顺序，但 ORDER BY 会增加 filesort 开销。通常不需要排序。

5. **大表 DELETE 同理**。参见 [案例 33](../ddl/44-batch-delete)，分批 DELETE 的原理和分批 UPDATE 完全一致。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 分批 UPDATE + LIMIT | ✅ 支持 | ✅ 支持 |
| undo log 管理 | 基础 | ✅ 改进的 purge 机制 |
| 在线 DDL | COPY/INPLACE | ✅ 新增 INSTANT 算法 |

::: tip 何时用分批
经验法则：单次 UPDATE/DELETE 影响行数超过 1 万行时，考虑分批。超过 10 万行时，必须分批。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 79-batch-update

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 79-batch-update --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 79-batch-update --no-seed
```
