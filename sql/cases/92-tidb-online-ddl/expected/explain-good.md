# EXPLAIN 参考结果 - good.sql（TiDB DDL 最佳实践）

## TiDB v7.5.1（20 万行数据）

> **说明**：DDL 语句不产生 EXPLAIN 输出。本文档展示最佳实践的对比分析和参数配置指南。

---

## 各 DDL 类型的锁行为和性能影响

| DDL 操作 | 是否阻塞 DML | 执行方式 | 20 万行预估耗时 | 对业务影响 | 建议执行窗口 |
|----------|-------------|---------|---------------|-----------|------------|
| ADD INDEX | **否** | 在线回填（backfill/ingest） | 30s - 2min | 轻微 I/O 和 CPU 增加 | 低峰期 |
| ADD COLUMN (DEFAULT NULL) | **否** | INSTANT | <1s | 无 | 任意时间 |
| ADD COLUMN (NOT NULL + DEFAULT) | **否** | 在线回填 | 10s - 60s | 轻微 I/O 增加 | 低峰期 |
| DROP INDEX | **否** | INSTANT（删元数据） | <1s | 无 | 任意时间 |
| DROP COLUMN | **否** | INSTANT | <1s | 无 | 任意时间 |
| MODIFY COLUMN | **否** | 在线重建表 | 1min - 10min | I/O + CPU + 磁盘空间 | **仅低峰期** |
| RENAME INDEX | **否** | INSTANT | <1s | 无 | 任意时间 |
| TRUNCATE TABLE | **是（短暂）** | 删除+重建 | <1s | 瞬间锁表 | 维护窗口 |
| ADD PRIMARY KEY | **否** | 在线回填 | 30s - 5min | 写入 I/O 增加 | 低峰期 |

---

## DDL 参数配置指南

### 关键参数

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `tidb_ddl_reorg_worker_cnt` | 4 | 4-8 | 回填阶段的并发 worker 数，提高可加速索引构建 |
| `tidb_ddl_reorg_batch_size` | 256 | 256-1024 | 每个事务回填的行数，增大可减少事务开销 |
| `tidb_ddl_reorg_priority` | `PRIORITY_LOW` | `PRIORITY_LOW` | 回填优先级，低优先级减少对业务的影响 |
| `tidb_ddl_error_count_limit` | 512 | 512 | 可重试错误次数上限，超过则 DDL 失败 |
| `tidb_ddl_disk_quota` | 100 GB | 根据磁盘调整 | ingest 模式下 SST 文件的磁盘配额 |

### 如何调优

```sql
-- 查看当前参数
SHOW VARIABLES LIKE 'tidb_ddl_reorg%';

-- 加速回填（适合低峰期大表添加索引）
SET GLOBAL tidb_ddl_reorg_worker_cnt = 8;
SET GLOBAL tidb_ddl_reorg_batch_size = 1024;

-- 减速回填（适合业务高峰期，减少影响）
SET GLOBAL tidb_ddl_reorg_worker_cnt = 2;
SET GLOBAL tidb_ddl_reorg_batch_size = 128;
```

---

## TiDB DDL vs MySQL Online DDL 差异表

| 特性 | MySQL 5.7 | MySQL 8.0 | TiDB |
|------|-----------|-----------|------|
| **默认 DDL 行为** | 多数 ALTER 会锁表/拷贝表 | INSTANT 支持有限场景 | **全部 Online，不阻塞读写** |
| **ALGORITHM 子句** | 支持 INPLACE/COPY | 支持 INPLACE/COPY/INSTANT | 忽略（语法兼容） |
| **LOCK 子句** | 支持 NONE/SHARED/EXCLUSIVE | 支持 NONE/SHARED/EXCLUSIVE | 忽略（语法兼容） |
| **ADD INDEX 机制** | INPLACE：逐行扫描回填 | INPLACE：逐行扫描回填 | backfill + **ingest（6.x+）** |
| **ingest 模式** | 不支持 | 不支持 | **支持**，通过 SST file 加速 |
| **ADD COLUMN INSTANT** | 不支持 | 支持（8.0+） | 原生支持 |
| **并发 DDL** | 串行（同一表） | 串行（同一表） | **集群级串行**（同一时刻只能 1 个 DDL） |
| **DDL 取消** | KILL 连接 | KILL 连接 | `ADMIN CANCEL DDL JOBS` |
| **DDL 暂停/恢复** | 不支持 | 不支持 | `ADMIN PAUSE/RESUME DDL JOBS` |
| **DDL 进度查看** | `SHOW PROCESSLIST` | `SHOW PROCESSLIST` + P_S | `ADMIN SHOW DDL JOBS`（含 ROW_COUNT） |
| **元数据锁** | MDL 可能阻塞业务 | MDL 可能阻塞业务 | **无 MDL**，通过 state transition 规避 |
| **失败回滚** | ALGORITHM=COPY 重做 | ALGORITHM=COPY 重做 | 自动清理中间状态 |
| **PT-OSC/gh-ost 需求** | 大表 DDL 常用 | 大表 DDL 常用 | **不需要**（原生在线 DDL） |

---

## 最佳实践清单

### 1. 添加索引

```sql
-- 正确：直接添加，无需 ALGORITHM/LOCK
ALTER TABLE t_ddl_test ADD INDEX idx_age (age);

-- 查看进度
ADMIN SHOW DDL JOBS 5;
```

### 2. 添加列

```sql
-- 正确：直接添加，秒级完成（DEFAULT NULL 时 INSTANT）
ALTER TABLE t_ddl_test ADD COLUMN phone VARCHAR(20) DEFAULT NULL;
```

### 3. 修改列类型

```sql
-- 评估影响：先检查表健康度
SHOW STATS_HEALTHY WHERE table_name = 't_ddl_test';

-- 执行修改（仅限低峰期）
ALTER TABLE t_ddl_test MODIFY COLUMN age BIGINT;

-- 监控进度
ADMIN SHOW DDL JOBS WHERE state = 'running';
```

### 4. DDL 任务管理

```sql
-- 查看最近 20 个 DDL 任务
ADMIN SHOW DDL JOBS 20;

-- 暂停某个 DDL（需在 write reorganization 阶段）
ADMIN PAUSE DDL JOBS 85;

-- 恢复暂停的 DDL
ADMIN RESUME DDL JOBS 85;

-- 取消某个 DDL
ADMIN CANCEL DDL JOBS 85;
```

### 5. 与 MySQL DDL 行为对比

| 场景 | MySQL 做法 | TiDB 做法 |
|------|-----------|-----------|
| 大表加索引 | `pt-online-schema-change` 或 `gh-ost` | 直接 `ALTER TABLE ... ADD INDEX` |
| 加列 | `ALGORITHM=INSTANT`（8.0+） | 直接 `ALTER TABLE ... ADD COLUMN` |
| DDL 进度 | 查 `sys.schema_*` 或工具面板 | `ADMIN SHOW DDL JOBS` |
| DDL 卡住 | KILL 或等 MDL 释放 | `ADMIN CANCEL DDL JOBS` |
