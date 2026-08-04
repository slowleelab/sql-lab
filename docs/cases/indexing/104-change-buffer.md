# Change Buffer 加速二级索引写入

<CaseMeta difficulty="⭐⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['Change Buffer', 'Insert Buffer', 'innodb_change_buffering', '写入优化', '二级索引']" />

## INSERT 吞吐只有 3000：5 个二级索引拖垮写入
某订单明细表有 5 个二级索引（按 user_id、按 product_id、按 status 等），业务大量 INSERT 但很少按这些二级索引查询（都是按主键查）。监控显示 INSERT 吞吐受限，磁盘 IO 高，tps 仅有 3000。但磁盘 IOPS 还有富余，似乎不是磁盘瓶颈。

```sql
-- 业务表：5 个二级索引的订单明细
INSERT INTO t_order_detail (order_id, user_id, product_id, status, amount, created_at)
VALUES (?, ?, ?, ?, ?, NOW());
-- 单条 INSERT ~0.3ms，tps 3000（瓶颈）
```

::: warning 真实场景
"写多读少"的业务（订单流水、日志、监控数据）常见问题：二级索引越多，INSERT 越慢。**Change Buffer** 是 InnoDB 在内存中缓存非唯一二级索引变更的机制——INSERT/UPDATE/DELETE 不直接写二级索引 page，而是先在内存中"记一笔"，后台线程再 merge 到磁盘。能将 INSERT 的随机 IO 转为顺序 IO。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 默认 innodb_change_buffering=all 已开启
-- 但二级索引太多，buffer pool 中相关 page 经常被淘汰，merge 频繁

-- 查看 Change Buffer 配置
SHOW VARIABLES LIKE 'innodb_change_buffering%';
-- innodb_change_buffering: all
-- innodb_change_buffer_max_size: 25 (占 buffer pool 25%)

-- 查看 Change Buffer 状态
SHOW ENGINE INNODB STATUS\G
-- 关注 "INSERT BUFFER AND ADAPTIVE HASH INDEX" 段
-- merge inserts / merged / purge merges 计数

-- 批量插入 10 万行到有 5 个二级索引的表
SET @start_time = NOW(6);
CALL seed_t_order_detail(100000);  -- 造 10 万行
SELECT TIMESTAMPDIFF(MICROSECOND, @start_time, NOW(6)) / 1000 AS ms;
-- 默认配置下 ~30s（tps 3333）
```

### 为什么慢

每条 INSERT 在 InnoDB 内部需维护：

| 索引类型 | 是否进 Change Buffer | 写入路径 |
|----------|--------------------|---------|
| 主键（聚簇索引） | ❌ 必须实时写 | 实时写 data page |
| 唯一二级索引 | ❌ 必须实时写 | 实时写（需检查唯一性） |
| **非唯一二级索引** | ✅ 可延迟 | **Change Buffer → 后台 merge** |

**默认配置已开启 Change Buffer**，但仍慢的常见原因：

1. **buffer pool 不足**：`innodb_change_buffer_max_size=25` 表示 Change Buffer 最多占 buffer pool 25%。buffer pool 本身小时，Change Buffer 容量也小
2. **二级索引 page 已被 buffer pool 缓存**：当 page 已在内存中时（最常见情况），Change Buffer 无效化，必须直接写 page
3. **merge 跟不上写入**：高并发 INSERT 时，merge 线程来不及处理，Change Buffer 满了后同步写入

## 优化方案

### good.sql

```sql
-- good.sql: 调大 Change Buffer 容量 + 减少不必要的二级索引

-- 1. 调大 Change Buffer 占 buffer pool 的比例（默认 25% → 50%）
SET GLOBAL innodb_change_buffer_max_size = 50;

-- 2. 确认 Change Buffer 模式（默认 all 已覆盖所有场景）
SHOW VARIABLES LIKE 'innodb_change_buffering';
-- all = inserts + deletes + purges（最全）
-- inserts / deletes / purges / none 可单独控制

-- 3. 业务层优化：删除用不到的二级索引
ALTER TABLE t_order_detail DROP INDEX idx_unused_status;  -- 业务不用 status 查询

-- 4. 重新跑批量插入
SET @start_time = NOW(6);
CALL seed_t_order_detail(100000);
SELECT TIMESTAMPDIFF(MICROSECOND, @start_time, NOW(6)) / 1000 AS ms;
-- 优化后 ~18s（tps 5500），约 1.6 倍加速
```

### 原理

**Change Buffer** 是 InnoDB 在 buffer pool 中为**非唯一二级索引**的变更开辟的特殊区域：

```
INSERT INTO t_order_detail (user_id=888, ...) 
  ├─ 主键（聚簇索引）→ 直接写 data page（必须实时）
  ├─ 唯一二级索引 (order_id) → 直接写（需唯一性检查）
  └─ 非唯一二级索引 (user_id, product_id) → Change Buffer!
       ├─ 内存中记录 (page_x, delta)
       └─ 后台线程 merge 到磁盘 page
```

**Change Buffer 关键参数**：

| 参数 | 默认 | 推荐 | 说明 |
|------|------|------|------|
| `innodb_change_buffering` | `all` | `all` | 包含 inserts/deletes/purges |
| `innodb_change_buffer_max_size` | `25` | `50`（写密集） | 占 buffer pool 百分比 |
| `innodb_change_buffering=inserts` | 关闭 deletes/purges | 不推荐 | 只缓冲 insert 性能略好但功能受限 |

**何时 Change Buffer 无效**：

- **唯一二级索引**：必须实时检查唯一性，不能缓冲
- **page 已在 buffer pool 中**：直接更新 page（仍要 redo log 刷盘）
- **change buffer 满**：退化为同步写入

### 对比

| | bad (默认 25%) | good (50% + 少索引) |
|---|---|---|
| Change Buffer 容量 | 128MB (512MB × 25%) | 256MB (512MB × 50%) |
| 二级索引数 | 5 个 | 4 个（删除不用索引） |
| 10 万行 INSERT 耗时 | ~30s | ~18s |
| tps | 3333 | 5555 |
| 磁盘随机 IO | 高 | 中（merge 平滑） |

<ExplainCompare
  :bad="{ type: 'N/A', key: '实时写 5 个索引', rows: '~30s/10万行', Extra: '磁盘 IO 抖动，Change Buffer 频繁刷新' }"
  :good="{ type: 'N/A', key: 'Change Buffer 50% + 少索引', rows: '~18s/10万行', Extra: '后台 merge 平滑，IO 平坦' }"
  improvement="INSERT 吞吐提升 1.6 倍，IO 抖动从 80% 降到 30%"
/>

## 避坑指南

::: warning 注意事项

1. **Change Buffer 仅对非唯一二级索引有效**。主键和唯一二级索引仍需实时写入。在表设计时，**尽量避免创建唯一二级索引**（除非确实需要唯一约束）——这是 Change Buffer 友好的关键。

2. **`innodb_change_buffering=inserts` 仅缓冲 INSERT，不缓冲 DELETE/UNDO 操作**。如果业务有大量 DELETE，写放大仍严重。推荐保持 `all`。

3. **Change Buffer 在崩溃恢复期间完全应用**。MySQL 异常关闭后重启，Change Buffer 内容会先于 redo log 应用，保证不丢失——这由 InnoDB 内部保证，无需应用层介入。

4. **监控 merge 速率**。`SHOW ENGINE INNODB STATUS` 中 `INSERT BUFFER AND ADAPTIVE HASH INDEX` 段的 `merge inserts/s` 是关键指标。如果远低于 `inserts/s`，说明 Change Buffer 跟不上写入。

5. **MySQL 8.0.13+ 可在线修改 `innodb_change_buffer_max_size`**。5.7 必须重启。在线调整需谨慎，先小范围验证。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `innodb_change_buffering` 默认 | `all` | `all` |
| `innodb_change_buffer_max_size` 默认 | 25 | 25 |
| 在线修改 max_size | ❌ 需重启 | ✅ 8.0.13+ 部分版本可动态 |
| Change Buffer 占用监控 | `SHOW ENGINE INNODB STATUS` | 同 5.7 + `INFORMATION_SCHEMA.INNODB_METRICS` |
| 与 `innodb_buffer_pool_instances` 关系 | 分散到各 instance | 同 5.7 |

::: tip 表设计建议
- **能用普通二级索引就别用唯一索引**——除非业务确实需要唯一约束
- **写多读少的表**（订单流水、日志）应精简二级索引，每个索引都让 INSERT 变慢
- **写完立即按该索引查**的场景（如 INSERT 后立刻按 user_id 查）反而应该让 page 进 buffer pool，避免 Change Buffer 失效
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 104-change-buffer

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 104-change-buffer --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 104-change-buffer --no-seed
```
