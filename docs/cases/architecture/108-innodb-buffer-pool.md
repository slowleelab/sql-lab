# InnoDB Buffer Pool 调优

<CaseMeta difficulty="⭐⭐⭐" category="架构级优化" versions="5.7 & 8.0" :tags="['innodb_buffer_pool_size', 'InnoDB', 'Buffer Pool', '内存调优', 'LRU']" />

## 100 万飙升
应用刚上线时跑得好好的，半年后数据量从 100 万涨到 5000 万，磁盘 IO 飙升、`SHOW PROCESSLIST` 出现大量"Writing to net"和"Reading from net"，QPS 断崖式下跌。检查 `innodb_buffer_pool_size` 设置才发现——只给了 128M，但数据库服务器有 64G 内存。

```sql
-- 查看当前 Buffer Pool 大小
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
-- +-------------------------+-----------+
-- | Variable_name           | Value     |
-- +-------------------------+-----------+
-- | innodb_buffer_pool_size | 134217728 |  -- 仅 128M！
-- +-------------------------+-----------+

-- 查看 Buffer Pool 命中率（应 > 99%）
SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
-- +----------------------------------+-------------+
-- | Variable_name                    | Value       |
-- +----------------------------------+-------------+
-- | Innodb_buffer_pool_read_requests | 1234567890  |
-- | Innodb_buffer_pool_reads         | 23456789    |  -- 磁盘读取次数
-- +----------------------------------+-------------+

-- 命中率 = 1 - (reads / requests)
-- 1 - 23456789/1234567890 = 98.1% （看似不低，但仍有 2% 走了磁盘）
```

更隐蔽的痛点：单实例 Buffer Pool 配置过大会导致 **dirty page 刷盘压力陡增**、**crash recovery 时间变长**（5.7 前 1TB Buffer Pool 重启要 1 小时+）。

::: warning 真实案例
某电商公司数据库服务器 64GB 内存，Buffer Pool 仅 8GB，QPS 5000 时磁盘 IO 长期 80% util。把 `innodb_buffer_pool_size` 调到 48GB 后，磁盘 IO 降至 5%，QPS 提升至 18000，**性能提升 3.6 倍**。
:::

## 问题分析

### bad.sql — 默认/保守配置

```sql
-- bad.sql: Buffer Pool 配置不当，性能严重浪费
-- 假设 64GB 内存服务器，Buffer Pool 仅 128M
SET GLOBAL innodb_buffer_pool_size = 134217728;  -- 128M

-- 验证命中率（执行 1000 次随机查询后查看）
SELECT BENCHMARK(1000, MD5(CONCAT(s.id, s.user_id))) AS warmup
FROM t_order s
WHERE s.created_at BETWEEN '2024-01-01' AND '2024-12-31';

SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
```

### 观察结果

执行前的 Buffer Pool 状态（用 `SHOW ENGINE INNODB STATUS\G` 摘录）：

```
Buffer pool size   8191  -- 8191 * 16KB = 128MB
Buffer pool hit    9823415 / 10000000 = 98.23%
Young-making rate  45/1000 not 0/1000
```

执行 1000 次随机查询后：

| 指标 | 数值 | 说明 |
|------|------|------|
| 请求总数 | 100,000 | 总读请求 |
| 物理读 | 1,768 | **命中磁盘 1.77%** |
| 命中率 | 98.23% | 看似不低，但热数据不断被踢出 |
| 平均响应时间 | 38ms | 物理读拉低 P99 |

### 为什么慢

InnoDB 的 Buffer Pool 本质是 **磁盘数据页的内存缓存**，缺失走磁盘：

1. **磁盘 vs 内存的代差**：随机读 SSD 约 100-500 μs，内存约 100 ns，**差 1000-5000 倍**
2. **LRU 算法会踢出"真正的热数据"**：
   - 全表扫描会把 buffer pool 灌满冷数据
   - 默认 `innodb_old_blocks_time=1000`（5.7+）让全表扫描的数据在 1s 内不晋升 LRU hot 区
   - 但小表的全表扫描仍可能污染 buffer pool
3. **多个 BP 实例的写竞争**：5.7 起支持 `innodb_buffer_pool_instances` 把 BP 拆成多个实例减少 mutex 竞争

::: tip 核心公式
**Buffer Pool 命中率应 > 99%**。若 < 95%，需考虑：
- 增大 `innodb_buffer_pool_size`（一般设为物理内存的 50-70%）
- 启用 `innodb_buffer_pool_instances`（建议 8 个，每个 1GB+）
- 启用 `innodb_buffer_pool_load_at_startup`（重启预热）
:::

## 优化方案

### good.sql — 调优配置

```sql
-- good.sql: 把 Buffer Pool 调大到物理内存的 60%（假设 64GB 内存）
SET GLOBAL innodb_buffer_pool_size = 42949672960;  -- 40GB

-- 多实例拆分（减少 mutex 竞争，建议 8 个，每个 ≥ 1GB）
SET GLOBAL innodb_buffer_pool_instances = 8;

-- 启用 BP dump/load（5.7+ 默认启用，重启时自动 load）
SET GLOBAL innodb_buffer_pool_dump_at_shutdown = ON;
SET GLOBAL innodb_buffer_pool_load_at_startup = ON;

-- 验证命中率
SELECT BENCHMARK(1000, MD5(CONCAT(s.id, s.user_id))) AS warmup
FROM t_order s
WHERE s.created_at BETWEEN '2024-01-01' AND '2024-12-31';

SHOW STATUS LIKE 'Innodb_buffer_pool_read%';
```

生产配置建议（`my.cnf`）：

```ini
[mysqld]
# 物理内存的 50-70%（留 30% 给 OS 缓存、连接、其他进程）
innodb_buffer_pool_size = 40G

# 多实例拆分（5.7+），每个 ≥ 1GB
innodb_buffer_pool_instances = 8

# 5.7+ 默认 ON，dump 5% 热页 + load
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON

# 8.0: chunk 动态调整，无需重启修改 BP 大小
innodb_buffer_pool_chunk_size = 128M
```

### 原理

**Buffer Pool 内部结构**：

```
Buffer Pool (总内存)
  ├── Instance 1 (5GB)
  │    ├── LRU List（最近访问的页）
  │    │    ├── young sublist（热数据，5/8）
  │    │    └── old sublist（候选，3/8，old_blocks_time 后才晋升）
  │    ├── Free List（空闲页）
  │    └── Flush List（脏页链表，等待刷盘）
  ├── Instance 2
  └── ... (8 instances total)
```

**关键参数**：

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `innodb_buffer_pool_size` | 128M | 物理内存 50-70% | 总大小 |
| `innodb_buffer_pool_instances` | 8（5.7+）| 8 | 实例数（每个 ≥ 1GB 才生效）|
| `innodb_buffer_pool_chunk_size` | 128M | 128M | 8.0 动态调整粒度 |
| `innodb_old_blocks_pct` | 37 | 37-50 | old sublist 占 LRU 比例 |
| `innodb_old_blocks_time` | 1000ms | 1000ms | 旧页停留时间，挡全表扫描 |

**多实例的 mutex 竞争**：

- 5.7 之前 BP 是单实例，所有读都要争抢一个 `buf_pool->LRU_list_mutex`
- 高并发下 mutex 成为瓶颈（sysbench 128 线程下 BP mutex 占 P95 20%+）
- 拆成 8 实例后，每个实例独立 LRU/BP mutex，**并发提升 30-50%**

### 对比

| | bad (128M) | good (40G) |
|---|---|---|
| Buffer Pool size | 128 MB | 40 GB |
| 实例数 | 1（5.7 后逻辑拆分但不够大）| 8 |
| 命中率 | 98.2% | **99.95%** |
| 平均读耗时 | 38ms | **80μs** |
| QPS | 5000 | 18000+ |
| 磁盘 IO 占用 | 80% | 5% |

sysbench OLTP_READ_ONLY 100GB 数据量对比（64GB 内存，SSD 磁盘）：

| 配置 | TPS | P99 延迟 |
|------|-----|----------|
| BP=8G, inst=1 | 3200 | 35ms |
| BP=16G, inst=4 | 7800 | 18ms |
| BP=32G, inst=8 | 14200 | 9ms |
| **BP=48G, inst=8** | **18500** | **6ms** |

<ExplainCompare
  :bad="{ type: 'Buffer Pool', key: '8GB 单实例', rows: '3200 TPS', Extra: '命中率 92%，频繁磁盘读' }"
  :good="{ type: 'Buffer Pool', key: '48GB/8 实例', rows: '18500 TPS', Extra: '命中率 99.95%' }"
  improvement="5.8 倍 TPS 提升，99% 物理读消除"
/>

## 避坑指南

::: warning 注意事项

1. **不要把内存全分给 BP**。建议保留 30% 给 OS 页缓存（`/proc/sys/vm/dirty_ratio` 调节）、连接线程、临时表、其他进程（如 mysqld_exporter）。

2. **`innodb_buffer_pool_instances` 仅在每个实例 ≥ 1GB 时生效**。如果你设了 8 个实例但 BP 只有 4G，MySQL 会自动回退为 4 个实例，每个 1GB。

3. **8.0 之前 BP 调整需重启**。5.7 修改 `innodb_buffer_pool_size` 需重启；8.0+ 引入 `innodb_buffer_pool_chunk_size`，可在线动态调整，无需重启。

4. **大 BP 重启时间长**。5.7 前 1TB BP 重启要 30+ 分钟（replay redo log）；5.7+ 启用 `innodb_buffer_pool_load_at_startup` 后，重启时自动 load 之前 dump 的热页，**1TB BP 重启时间从 1h 降到 3-5min**。

5. **大 BP + 小 redo log 会频繁 checkpoint**。如果 BP 50GB 但 `innodb_log_file_size` 只 1GB，会触发大量 `adaptive checkpoint`，反而降低写性能。建议 redo log 总大小为 BP 的 10-25%。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 在线修改 BP 大小 | ❌ 需重启 | ✅ `innodb_buffer_pool_chunk_size` 粒度 |
| BP load/dump | ✅ 需 `innodb_buffer_pool_dump_at_shutdown=ON` | ✅ 默认 ON |
| BP 拆分实例 | ✅ | ✅ |
| 资源组绑定 | ❌ | ✅ `innodb_buffer_pool_resize_chunk_size` |
| 自动内存管理 | ❌ | ❌（MySQL HeatWave 才有）|

::: tip 8.0 在线调整示例
```sql
-- 8.0 可在线调整，无需重启
SET GLOBAL innodb_buffer_pool_size = 50 * 1024 * 1024 * 1024;  -- 50GB
-- 自动按 chunk 粒度（128MB）平滑增长，期间不阻塞读写
```
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 108-innodb-buffer-pool

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 108-innodb-buffer-pool --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 108-innodb-buffer-pool --no-seed
```
