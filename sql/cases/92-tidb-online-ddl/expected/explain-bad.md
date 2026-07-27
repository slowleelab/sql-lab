# EXPLAIN 参考结果 - bad.sql（DDL 误区分析）

## TiDB v7.5.1（20 万行数据）

> **说明**：DDL 语句不产生 EXPLAIN 输出。本文档通过状态转换表和流程说明，解读 TiDB DDL 的执行机制和常见误区。

---

## DDL 多阶段状态转换图

TiDB DDL 采用多阶段滑移（State Transition）协议，每个 DDL 操作的对象（表/列/索引）经历以下 5 个状态：

```
absent  ──►  delete only  ──►  write only  ──►  write reorganization  ──►  public
(不存在)     (只删不读)       (只写不读)        (回填/重建)                  (公开可用)
```

| 阶段 | 状态 | DML 可见性 | 说明 |
|------|------|-----------|------|
| 1 | `absent` | — | DDL 对象尚未创建（对 ADD 操作而言） |
| 2 | `delete only` | DELETE 可见，INSERT/UPDATE/SELECT 不可见 | 用于安全回滚，一旦进入此状态，元数据已提交无法回退 |
| 3 | `write only` | INSERT/UPDATE/DELETE 可见，SELECT 不可见 | 新写入数据包含此对象，但查询返回旧 schema |
| 4 | `write reorganization` | 后台回填（backfill） | 对已存在的行进行回填（如索引构建），此阶段最耗时 |
| 5 | `public` | 完全可见 | DDL 完成，对象对所有操作可见 |

---

## 常见 DDL 类型在各阶段的耗时估算

| DDL 类型 | delete only | write only | write reorg | public | 总耗时估计（20 万行）| DML 阻塞？ |
|----------|-------------|------------|-------------|--------|---------------------|-----------|
| ADD INDEX | <1s | <1s | 10s-60s（backfill） | <1s | 10-60s | **否** |
| ADD COLUMN（DEFAULT NULL） | <1s | <1s | <1s | <1s | <1s | **否**（INSTANT） |
| ADD COLUMN（带 NOT NULL + DEFAULT） | <1s | <1s | 5s-30s | <1s | 5-30s | **否** |
| DROP INDEX | <1s | — | — | <1s | <1s | **否**（只删元数据） |
| MODIFY COLUMN（类型兼容） | <1s | <1s | 20s-120s（重写） | <1s | 20-120s | **否** |
| MODIFY COLUMN（类型不兼容） | <1s | <1s | 60s-300s（重写+转换） | <1s | 60-300s | **否** |
| DROP COLUMN | <1s | <1s | <1s | <1s | <1s | **否**（INSTANT） |
| TRUNCATE TABLE | <1s | — | — | — | <1s | **是**（需短暂锁） |

---

## ADMIN SHOW DDL JOBS 输出解读

```sql
ADMIN SHOW DDL JOBS;
```

典型输出：

```
+--------+---------+------------+--------------+----------------------+-----------+----------+-----------+---------------------+
| JOB_ID | DB_NAME | TABLE_NAME | JOB_TYPE     | SCHEMA_STATE         | SCHEMA_ID | TABLE_ID | ROW_COUNT | START_TIME          |
+--------+---------+------------+--------------+----------------------+-----------+----------+-----------+---------------------+
|     85 | test    | t_ddl_test | add index    | write reorganization |         1 |       42 |    120000 | 2024-01-15 10:30:00 |
+--------+---------+------------+--------------+----------------------+-----------+----------+-----------+---------------------+
```

| 字段 | 含义 | 关注点 |
|------|------|--------|
| `JOB_ID` | DDL 任务唯一 ID | 用于 ADMIN PAUSE/RESUME DDL JOBS |
| `JOB_TYPE` | DDL 类型 | `add index` / `modify column` / `add column` 等 |
| `SCHEMA_STATE` | 当前状态 | `write reorganization` 表示正在回填 |
| `ROW_COUNT` | 已回填行数 | 对比表总行数估算进度 |
| `START_TIME` | 任务开始时间 | 判断 DDL 是否长时间卡住 |

---

## 误区 1: 指定 ALGORITHM=INPLACE

```sql
ALTER TABLE t_ddl_test ADD INDEX idx_name (name) ALGORITHM=INPLACE;
```

- TiDB **忽略** ALGORITHM 和 LOCK 子句（语法兼容但不生效）
- TiDB DDL 始终以在线方式执行，不存在 ALGORITHM=COPY 的全表拷贝模式
- 与 MySQL 不同：MySQL 中 ALGORITHM=INPLACE 是可选优化，TiDB 中是**唯一且默认**的行为

## 误区 2: 以为 MODIFY COLUMN 可以快速完成

```sql
ALTER TABLE t_ddl_test MODIFY COLUMN age BIGINT;
```

- `MODIFY COLUMN` 在 TiDB 中会被视为**表重建操作**（即使 INT->BIGINT 在 MySQL 中可能是 metadata-only）
- 20 万行的表可能需要数分钟，期间虽然不阻塞读写，但会产生额外 I/O 和 CPU 开销
- 建议在低峰期执行，并通过 `ADMIN SHOW DDL JOBS` 监控进度

## 误区 3: 未关注 DDL 进度

DDL 任务执行期间：
- 如果 DDL 卡在 `write reorganization` 阶段超过预期时间，可能是 `tidb_ddl_reorg_worker_cnt` 参数过低
- 通过 `ADMIN SHOW DDL JOBS WHERE state = 'running'` 定位长时间运行的 DDL

---

## TiDB DDL 与 MySQL Online DDL 核心差异

| 维度 | MySQL 8.0 | TiDB |
|------|-----------|------|
| 语法 | 需要 `ALGORITHM=INPLACE` / `LOCK=NONE` | 忽略 ALGORITHM/LOCK（写了也没用） |
| 默认行为 | 部分 DDL 需显式指定才在线 | **所有 DDL 默认在线** |
| 索引构建 | INPLACE 模式逐行扫描 | 6.x+ 支持 **ingest 模式**（基于 SST file 导入） |
| INSTANT DDL | 8.0 支持 ADD COLUMN INSTANT | 原生支持 ADD/DROP COLUMN INSTANT |
| 阻塞情况 | 元数据锁可能阻塞 | state transition 协议，无元数据锁冲突 |
| 回滚 | ALGORITHM=COPY 可 KILL | 支持 ADMIN CANCEL DDL JOBS |
| 并发 DDL | 串行执行 | 串行执行（同一集群同一时间只允许一个 DDL） |
