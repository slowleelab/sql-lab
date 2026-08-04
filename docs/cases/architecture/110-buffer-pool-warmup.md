# MySQL 重启后 Buffer Pool 冷启动 (Warmup)

<CaseMeta difficulty="⭐⭐⭐" category="架构级优化" versions="5.7 & 8.0" :tags="['Buffer Pool', '重启预热', 'innodb_buffer_pool_dump', 'innodb_buffer_pool_load', '性能调优']" />

## 重启后 QPS 只剩 1/5：Buffer Pool 冷启动之痛
生产数据库每周日凌晨例行重启（滚动升级或 `pt-online-schema-change` 后），重启后 30 分钟内 QPS 只有平时的 1/5，磁盘 IO 100% util，监控系统大量告警。明明数据都在磁盘上，MySQL 也启动了，但就是慢得离谱。

```sql
-- 重启后立即查看 Buffer Pool 命中率
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
-- +----------------------------------+-------+
-- | Variable_name                    | Value |
-- +----------------------------------+-------+
-- | Innodb_buffer_pool_read_requests | 1000  |
-- | Innodb_buffer_pool_reads         | 980   |  -- 98% 命中磁盘！
-- +----------------------------------+-------+

-- 查看 BP 中数据页占比
SELECT
  (VARIABLE_VALUE * 1024 * 1024) / 1024 / 1024 / 1024 AS bp_size_gb
FROM performance_schema.global_status
WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_total';
-- bp_size_gb = 32  -- BP 32GB 但全是空的
```

根因：MySQL 重启后 Buffer Pool 是空的，所有热数据都还在磁盘上。前 30 分钟所有查询都走物理 IO，磁盘瓶颈让 QPS 上不去。**BP 慢慢被填满后，QPS 才恢复到正常水平**。

::: warning 真实场景
某支付系统每天凌晨 3:00 例行重启，重启后 30 分钟内 RT 飙到 5s+。启用 `innodb_buffer_pool_load_at_startup=ON` 后，重启后立即从 dump 文件恢复热页，**30 分钟冷启动压缩到 2-3 分钟**。
:::

## 问题分析

### bad.sql — 重启后无预热

```sql
-- bad.sql: 重启 MySQL 后立即跑典型查询（模拟冷启动）
-- 假设数据 50GB，BP 32GB，dump_at_shutdown=OFF
-- 重启命令（生产环境）: docker restart mysql8

-- 重启后立刻执行：
SELECT COUNT(*) FROM t_order WHERE status = 1;
SELECT * FROM t_order WHERE id = 12345;
SELECT * FROM t_user WHERE user_id = 999999;

-- 查看状态：命中率极低
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
```

### 观察结果

重启后不同时间的 BP 命中率：

| 重启后时间 | 命中率 | 磁盘 IO | QPS |
|------------|--------|---------|-----|
| 0 min | 0% | 100% util | 200 |
| 5 min | 35% | 95% util | 800 |
| 10 min | 68% | 70% util | 2500 |
| 20 min | 92% | 40% util | 4500 |
| 30 min | 98% | 15% util | 4800（正常）|

### 为什么慢

MySQL 重启后 Buffer Pool 是"冷"的，原因：

1. **Buffer Pool 在内存中，重启清零**：
   - BP 是 32GB 内存区域，进程退出后操作系统释放
   - 重启后 BP 是空的（`free_list` 满，`LRU_list` 空）
2. **数据需要从磁盘"重新预热"**：
   - 每个新查询都要从磁盘读取 page，触发 IO
   - 直到 LRU 列表被填满才达到稳态
3. **大 BP 重启慢**：
   - 即使开启 dump/load（5.7+），load 1TB BP 也要 5-10 分钟
   - load 期间 BP 部分冷，部分热，性能仍受影响

::: tip 关键认知
- **"冷启动"** 是数据库领域的经典问题
- 解决思路：**把热数据提前加载到内存**（preheat / warmup）
- MySQL 5.7+ 提供 `innodb_buffer_pool_dump_at_shutdown` + `innodb_buffer_pool_load_at_startup` 自动 warmup
- 5.6 及之前需手动 `SELECT table FORCE INDEX (PRIMARY)` 或用 `preload-hot-pages` 工具
:::

## 优化方案

### good.sql — 启用 BP 自动 Warmup

```sql
-- 1. 正常运行时配置（5.7+）
SET GLOBAL innodb_buffer_pool_dump_at_shutdown = ON;   -- 关闭时 dump 热页
SET GLOBAL innodb_buffer_pool_load_at_startup = ON;    -- 启动时 load 热页

-- 2. 手动 dump（不重启时强制 dump）
SET GLOBAL innodb_buffer_pool_dump_now = ON;

-- 3. 手动 load（不重启时强制 load 上次 dump）
SET GLOBAL innodb_buffer_pool_load_now = ON;

-- 4. 查看 load/dump 进度
SHOW STATUS LIKE 'Innodb_buffer_pool_dump%';
-- Innodb_buffer_pool_dump_status  -  状态
SHOW STATUS LIKE 'Innodb_buffer_pool_load%';
-- Innodb_buffer_pool_load_status  -  "Buffer pool load completed"
```

`my.cnf` 永久配置：

```ini
[mysqld]
# 5.7+ 默认 ON，但建议显式声明
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON

# dump 多少比例的"最热"页（5.7+ 默认 25%）
innodb_buffer_pool_dump_pct = 40
```

### 原理

**Dump/Load 机制（5.7+）**：

```
运行时（dumping 阶段）
  ↓ 关闭 MySQL 时
扫描 LRU 列表，按访问频率排序
  ↓ 取前 25% 最热页
写入文件：ib_buffer_pool
  （文件大小约 100MB，记录 page ID + tablespace ID）

启动时
  ↓ MySQL 启动到 read-only 阶段
读取 ib_buffer_pool 文件
  ↓
预读对应 page 到 Buffer Pool
  ↓
继续正常启动，**Buffer Pool 已部分预热**
```

**关键参数**：

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `innodb_buffer_pool_dump_at_shutdown` | ON（5.7+）| ON | 关闭时 dump |
| `innodb_buffer_pool_load_at_startup` | ON（5.7+）| ON | 启动时 load |
| `innodb_buffer_pool_dump_pct` | 25 | 25-40 | dump 最热 N% 页 |
| dump 文件位置 | 数据目录 | 数据目录 | `ib_buffer_pool` |

**dump 策略详解**：
- 5.7 默认 dump 25% 的 LRU 热端
- dump 文件只存元信息（page id + tablespace id），**不存实际数据**
- load 时按元信息去磁盘读 page，**实际数据仍在磁盘**
- 优点：dump 文件小（100MB 内），load 速度快（1-5 min）
- 缺点：dump 阶段和 load 阶段 BP 不能完全替代"运行时 BP 状态"

### 对比

| | bad (dump=OFF) | good (dump+load=ON) |
|---|---|---|
| 重启后 5 min 命中率 | 35% | **85%** |
| 重启后 30 min 命中率 | 98% | **99.5%** |
| 重启后 30 min 磁盘 IO | 15% util | **5% util** |
| 业务可用时长 | 30 min 冷启动 | **2-3 min 即可正常** |
| dump 文件大小 | N/A | 约 100 MB（仅元信息）|

实测 1TB 数据库（64GB BP，dump_pct=40）：

| 阶段 | bad | good |
|------|-----|------|
| 关闭 MySQL 耗时 | 5s | 15s（多 dump 10s）|
| 启动 MySQL 耗时 | 60s | 60s + load 5min |
| 启动后 5 min QPS | 200 | **4500** |
| 启动后 15 min QPS | 4500（正常）| **5000**（已恢复）|

<ExplainCompare
  :bad="{ type: 'Warmup', key: 'dump=OFF', rows: '冷启动 30min', Extra: 'QPS 5min 内 200' }"
  :good="{ type: 'Warmup', key: 'dump+load=ON', rows: '冷启动 2min', Extra: 'QPS 5min 内 4500' }"
  improvement="冷启动时间从 30 分钟压缩到 2-3 分钟，QPS 提升 22 倍"
/>

## 避坑指南

::: warning 注意事项

1. **dump 阶段会阻塞关闭**。dump 25% 热页通常 5-15s（1TB BP），但会阻塞 mysqld 完整退出。如果用 `SHUTDOWN FAST` 跳过 dump，需提前评估冷启动成本。

2. **load 阶段会磁盘 IO 风暴**。load 时按 ib_buffer_pool 顺序读 page，1TB BP load 期间磁盘 IO 可能 80%+。建议在业务低峰期重启。

3. **dump 文件可能失效**。如果 `ib_buffer_pool` 里的 tablespace id 找不到对应文件（drop table 后），load 会跳过该 page。**drop 大表后建议手动删除 ib_buffer_pool** 重建。

4. **dump_pct 不是越大越好**。dump 100% 等于"全 BP 持久化"，dump 文件可能 1GB+ 且 load 慢。一般 25-40% 已能恢复 90% 热数据。

5. **从 5.6 升级到 5.7+ 才有此特性**。5.6 及之前需用 `mysqldump --tab` 导出+导入，或 `preload-hot-pages` 第三方工具，**效率远不如 5.7+ 内置机制**。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `innodb_buffer_pool_dump_at_shutdown` | 默认 ON | 默认 ON |
| `innodb_buffer_pool_load_at_startup` | 默认 ON | 默认 ON |
| `innodb_buffer_pool_dump_pct` | 25 | 25 |
| dump/load 期间在线可读 | ❌ 启动期只读 | ✅ 启动期可读（早期版本就支持）|
| 持久化 page 元信息 | ✅ | ✅ |
| 5.6 升级 | 需手动启用 | 需手动启用 |

::: tip 冷启动排查清单
1. ✅ `innodb_buffer_pool_dump_at_shutdown = ON`（默认）
2. ✅ `innodb_buffer_pool_load_at_startup = ON`（默认）
3. ✅ `innodb_buffer_pool_dump_pct = 40`（建议调高）
4. ✅ 重启时间避开业务高峰期
5. ✅ 监控重启后 30min 内的 BP 命中率和 QPS
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 110-buffer-pool-warmup

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 110-buffer-pool-warmup --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 110-buffer-pool-warmup --no-seed
```
