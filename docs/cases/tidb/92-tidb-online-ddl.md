# TiDB 在线 DDL 机制

<CaseMeta difficulty="⭐⭐" category="TiDB 分布式优化" versions="TiDB" :tags="['DDL', 'Online Schema Change', 'Schema Change', 'ingest']" />

## 场景痛点

你是一名从 MySQL 迁移到 TiDB 的 DBA。在 MySQL 中做 DDL，你习惯了这样的流程：

1. 先用 `pt-online-schema-change` 或 `gh-ost` 评估风险
2. 然后小心翼翼地加上 `ALGORITHM=INPLACE, LOCK=NONE`
3. 再打开监控盯着 `SHOW PROCESSLIST` 看进度
4. 祈祷不要触发 MDL 锁把整个业务卡死

到了 TiDB 之后，你发现：

- TiDB 的 DDL **没有** ALGORITHM 和 LOCK 的概念（写了也被忽略）
- TiDB 的 DDL **默认不阻塞读写**，不需要 pt-osc/gh-ost 这类外部工具
- TiDB 的 DDL 进度需要用 `ADMIN SHOW DDL JOBS` 查看，而不是 `SHOW PROCESSLIST`

但这也带来了新的困惑：哪天 ALTER TABLE 慢了你不知道怎么排查，参数不知道怎么调，进度不知道怎么跟踪。更关键的是，添加索引在 TiDB 6.x 中引入了 **ingest 模式**，行为和老版本截然不同。

::: warning 真实场景
几乎所有 MySQL DBA 初次接触 TiDB 时都会在 DDL 上踩坑：有人以为只要不加 ALGORITHM=COPY 就不会有问题，殊不知 TiDB 的 MODIFY COLUMN 会触发全表重写；也有人听说 TiDB DDL 不锁表，就大胆在业务高峰期加索引，结果 CPU 打满被运维找上门。
:::

## 问题分析

### bad.sql：DDL 常见误区

```sql
-- 误区 1: 不关注 DDL 进度
ADMIN SHOW DDL JOBS;

-- 误区 2: 画蛇添足指定 ALGORITHM
ALTER TABLE t_ddl_test ADD INDEX idx_name (name) ALGORITHM=INPLACE;

-- 误区 3: 随意 MODIFY COLUMN
ALTER TABLE t_ddl_test MODIFY COLUMN age BIGINT;

-- 误区 4: 高并发时执行 DDL，不调整参数
SHOW VARIABLES LIKE 'tidb_ddl_reorg_worker_cnt';
SHOW VARIABLES LIKE 'tidb_ddl_reorg_batch_size';

-- 误区 5: 不知道如何定位慢 DDL
ADMIN SHOW DDL JOBS WHERE state = 'running';
```

### TiDB DDL 的多阶段滑移协议

TiDB DDL 的核心设计是**多阶段滑移（State Transition）协议**。每个 DDL 对象（索引、列）都会经历 5 个状态：

```
absent ──▶ delete only ──▶ write only ──▶ write reorganization ──▶ public
```

| 阶段 | 状态 | 读 | 写 | 说明 |
|------|------|-----|-----|------|
| 1 | `absent` | 不可见 | 不可见 | 对象尚未创建 |
| 2 | `delete only` | 不可见 | 删除可见 | 元数据已提交，此状态保证可以安全回滚 |
| 3 | `write only` | 不可见 | 增删改均可见 | 新写入的数据会维护该对象，但查询仍走旧 schema |
| 4 | `write reorganization` | 不可见 | 可见 | **后台回填**——对已存在的行进行批量填充（最耗时阶段） |
| 5 | `public` | 可见 | 可见 | DDL 完成，对象对所有操作完全可用 |

这个协议的关键优势是：**所有阶段都不阻塞 DML**。`write reorganization` 虽然是批量回填，但使用的是低优先级、分批提交的方式，对业务写入的影响降到最低。

### MySQL Online DDL 为什么需要 ALGORITHM=INPLACE？

MySQL 的在线 DDL 是后来"打补丁"加上去的设计，历史上存在 ALGORITHM=COPY（全表拷贝），所以需要通过语法来区分。TiDB 从一开始就设计为在线 DDL，不存在 COPY 模式，因此完全不需要 ALGORITHM 子句。

### 误区详解

**误区 1: 不关注 DDL 进度**
`ADMIN SHOW DDL JOBS` 是 TiDB 独有的 DDL 管理命令，输出包含 `ROW_COUNT`（已回填行数）和 `SCHEMA_STATE`（当前状态）。不关注这些就容易在 DDL 执行期间无所适从。

**误区 2: 画蛇添足指定 ALGORITHM**
虽然 TiDB 兼容 `ALGORITHM=INPLACE` 语法（不会报错），但它实际上被忽略。TiDB DDL 始终以 Online 方式执行，不能选择 COPY 模式——这不是限制，而是设计上就不需要。

**误区 3: 随意 MODIFY COLUMN**
在 TiDB 中，`MODIFY COLUMN`（即使是兼容的类型变更，如 INT -> BIGINT）会触发**全表重建**。对于大表而言，这是一个重操作，应该安排在低峰期。

**误区 4: 高并发时不调整回填参数**
`tidb_ddl_reorg_worker_cnt`（回填并发数）和 `tidb_ddl_reorg_batch_size`（每批行数）直接影响 DDL 速度和业务影响的平衡。默认值相对保守，在低峰期可以调激进一些加速完成。

**误区 5: 不知道如何定位卡住的 DDL**
TiDB 同一时间只能执行一个 DDL 任务（集群级串行）。如果前一个 DDL 卡住，后续所有 DDL 都会被阻塞。需要及时定位并选择暂停或取消。

## 优化方案

### good.sql：TiDB DDL 最佳实践

```sql
-- 1. 查看 DDL 历史，了解进度
ADMIN SHOW DDL JOBS 20;
ADMIN SHOW DDL JOB QUERIES;

-- 2. 在低峰期调优回填参数，加速完成
SET GLOBAL tidb_ddl_reorg_worker_cnt = 4;
SET GLOBAL tidb_ddl_reorg_batch_size = 256;

-- 3. 添加索引——直接加，无需 ALGORITHM/LOCK
ALTER TABLE t_ddl_test ADD INDEX idx_age (age);

-- 4. 添加列——秒级 INSTANT
ALTER TABLE t_ddl_test ADD COLUMN phone VARCHAR(20) DEFAULT NULL;

-- 5. MODIFY COLUMN 前评估影响
SHOW STATS_HEALTHY WHERE table_name = 't_ddl_test';

-- 6. 善用暂停/恢复/取消机制
-- ADMIN PAUSE DDL JOBS job_id;
-- ADMIN RESUME DDL JOBS job_id;
-- ADMIN CANCEL DDL JOBS job_id;
```

### 关键优化策略

#### 1. 索引构建：backfill vs ingest

- **TiDB 5.x 及以前**：ADD INDEX 通过 `backfill` 方式，使用 `tidb_ddl_reorg_worker_cnt` 个 worker 逐行扫描表并构建索引
- **TiDB 6.x+**：引入 **ingest 模式**，将索引数据写入 SST 文件，然后直接导入到 TiKV RocksDB。相比 backfill，ingest 大幅减少了事务开销和回填时间

ingest 模式的控制参数：

```sql
-- 查看是否开启 ingest
SHOW VARIABLES LIKE 'tidb_ddl_enable_fast_reorg';

-- 设置 ingest 磁盘配额（默认 100 GB）
SET GLOBAL tidb_ddl_disk_quota = 200 * 1024 * 1024 * 1024; -- 200 GB
```

#### 2. INSTANT DDL：零等待的列操作

TiDB 支持多种 INSTANT DDL（秒级完成，与数据量无关）：

| 操作 | 是否 INSTANT | 条件 |
|------|-------------|------|
| ADD COLUMN ... DEFAULT NULL | **是** | — |
| ADD COLUMN ... NOT NULL DEFAULT ... | **是**（部分版本） | TiDB 7.x+ |
| DROP COLUMN | **是** | — |
| RENAME COLUMN | **是** | — |
| MODIFY COLUMN ... DEFAULT ... | **是** | 仅改默认值 |
| ADD INDEX / DROP INDEX | 否 | 需回填 / 只删元数据 |

#### 3. DDL 生命周期管理

TiDB 提供了独特的 DDL 任务管理能力，这在 MySQL 中是不存在的：

```sql
-- 暂停 DDL（需在 write reorganization 阶段）
ADMIN PAUSE DDL JOBS 85;

-- 恢复 DDL
ADMIN RESUME DDL JOBS 85;

-- 取消 DDL
ADMIN CANCEL DDL JOBS 85;
```

这允许 DBA 在 DDL 执行期间灵活调整：比如高峰期暂停，夜间恢复继续。

### bad vs good 量化对比

| 维度 | bad.sql（误区做法） | good.sql（最佳实践） | 提升 |
|------|---------------------|---------------------|------|
| 添加索引语法 | `ADD INDEX ... ALGORITHM=INPLACE`（冗余） | `ADD INDEX ...`（简洁） | 无功能差异，减少误解 |
| 进度可见性 | 不查或不知道查什么 | `ADMIN SHOW DDL JOBS` 精确跟踪 | 从"黑盒等待"到精确掌握 |
| 参数调优 | 使用默认参数，可能很慢 | 低峰期调高 worker 和 batch | 回填速度可提升 2-4x |
| MODIFY COLUMN | 随意执行 | 评估影响 + 低峰期执行 | 避免业务高峰期的性能冲击 |
| DDL 卡住处理 | 不知道怎么办 | PAUSE / CANCEL / RESUME | 从被动等待到主动管理 |
| 外部工具依赖 | 担心锁表，考虑 pt-osc/gh-ost | 原生 DDL，无需外部工具 | 运维复杂度降低 100% |

## 避坑指南

::: warning 注意事项

1. **TiDB DDL 是集群级串行的**。同一时刻整个集群只能执行一个 DDL。如果前一个 DDL 卡住，后面所有 DDL 都会排队等待。务必通过 `ADMIN SHOW DDL JOBS` 关注队列状态。

2. **MODIFY COLUMN 是重操作**。即使是 INT -> BIGINT 这种看似"兼容"的类型变更，TiDB 也会触发全表重建。在 20 万行的表上可能需要数分钟，大表则需要数小时。

3. **ingest 模式需要磁盘空间**。`tidb_ddl_disk_quota` 控制 ingest 模式下的 SST 文件磁盘配额，默认 100 GB。如果磁盘空间不足，DDL 会失败。在磁盘紧张的集群上需提前检查。

4. **ADD INDEX 仍需要时间**。虽然 TiDB DDL 不阻塞读写，但大表（亿级）添加索引的回填时间可能以小时计。建议评估业务影响，在低峰期执行。

5. **DDL 无法完全"无感"**。虽然 DML 不会被阻塞，但回填过程的 I/O 和 CPU 开销会影响整体集群性能，高并发写入场景下仍可能导致业务延迟上升。

6. **不要用 MySQL 思维理解 TiDB DDL**。MySQL 的 `ALGORITHM=INPLACE`、`LOCK=NONE`、元数据锁（MDL）、pt-osc/gh-ost —— 这些概念在 TiDB 中要么不存在，要么完全不同。学习 TiDB DDL 需要重新建立认知模型。

7. **TiDB DDL 不支持回滚到执行前**。`ADMIN CANCEL DDL JOBS` 会取消 DDL 并清理中间状态，但不是"回滚"（比如 ADD INDEX 被取消后索引不存在，但不是回到之前的某个快照）。

8. **关注 DDL 的 `ROW_COUNT`**。`ADMIN SHOW DDL JOBS` 中的 `ROW_COUNT` 是已回填行数。对于大表，如果 ROW_COUNT 长时间不增长，可能是 DDL 卡住了，需要检查 TiKV 节点的状态。

9. **ingest 模式不是银弹**。ingest 虽然快，但它会将大量 SST 文件一次性导入 TiKV，可能导致 compaction 压力增大。在 TiKV 压力本就大的集群上，应谨慎开启。
:::

## TiDB DDL vs MySQL DDL 对比表

| 特性 | MySQL 5.7 | MySQL 8.0 | TiDB |
|------|-----------|-----------|------|
| **默认 DDL 行为** | 多数 ALTER 会锁表/拷贝表 | INSTANT 支持有限场景 | **全部 Online，不阻塞读写** |
| **ALGORITHM 子句** | 支持 INPLACE/COPY | 支持 INPLACE/COPY/INSTANT | 忽略（语法兼容） |
| **LOCK 子句** | 支持 NONE/SHARED/EXCLUSIVE | 支持 NONE/SHARED/EXCLUSIVE | 忽略（语法兼容） |
| **ADD INDEX 机制** | INPLACE：逐行扫描回填 | INPLACE：逐行扫描回填 | backfill + **ingest（6.x+）** |
| **ingest 模式** | 不支持 | 不支持 | **支持**，通过 SST file 加速 |
| **ADD COLUMN INSTANT** | 不支持 | 支持（8.0.12+） | 原生支持 |
| **并发 DDL** | 串行（同一表） | 串行（同一表） | **集群级串行**（同一时刻只能 1 个 DDL） |
| **DDL 取消** | KILL 连接 | KILL 连接 | `ADMIN CANCEL DDL JOBS` |
| **DDL 暂停/恢复** | 不支持 | 不支持 | `ADMIN PAUSE/RESUME DDL JOBS` |
| **DDL 进度查看** | `SHOW PROCESSLIST` | `SHOW PROCESSLIST` + P_S | `ADMIN SHOW DDL JOBS`（含 ROW_COUNT） |
| **元数据锁（MDL）** | 有，可能阻塞业务 | 有，可能阻塞业务 | **无 MDL**，通过 state transition 规避 |
| **PT-OSC/gh-ost 需求** | 大表 DDL 常用 | 大表 DDL 常用 | **不需要**（原生在线 DDL） |
| **DDL 失败处理** | ALGORITHM=COPY 重做 | ALGORITHM=COPY 重做 | 自动清理中间状态 |
| **DDL 回填优先级** | 正常优先级 | 正常优先级 | 低优先级（PRIORITY_LOW），减少业务影响 |
| **DROP COLUMN** | INPLACE（非 INSTANT） | INSTANT（8.0.29+） | **INSTANT** |
| **TRUNCATE TABLE** | 短暂锁表（DROP + CREATE） | 短暂锁表（DROP + CREATE） | 短暂锁表 |

## 本地复现

```bash
./scripts/run-case.sh 92-tidb-online-ddl --ver tidb
```

::: tip 系统要求
需要本地或远端 TiDB 实例。可以使用 `tiup playground` 快速启动本地集群：

```bash
tiup playground v7.5.1 --db 1 --kv 1
```
:::
