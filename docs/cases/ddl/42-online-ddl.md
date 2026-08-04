# 大表加索引 Online DDL

<CaseMeta difficulty="⭐⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['Online DDL', '加索引', 'ALGORITHM', 'LOCK', 'INSTANT']" />

## 200 万行加索引：一条 DDL 锁表到不可用
线上有一张 200 万行的业务表，`user_id` 列没有索引，导致按用户查询慢到不可用。DBA 决定加索引，随手敲下：

```sql
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id);
```

结果这条 DDL 执行了 **8 分钟**，期间整张表完全不可写，线上订单写入全部超时排队，监控告警一片飘红。

这就是 **"大表加索引锁表"** 事故--在没有显式指定 Online DDL 算法的情况下，某些操作或版本会退化到 `ALGORITHM=COPY`：建临时表、逐行拷贝、全程持表锁，对在线业务是灾难性的。

::: warning 真实场景
这几乎是每个 DBA 都踩过的坑。表越大，锁表时间越长。百万行表可达分钟级，千万行表可达十分钟级。主从架构下，从库回放同样耗时，期间数据严重滞后。
:::

## 问题分析

### bad.sql

```sql
-- 传统方式加索引：ALGORITHM=COPY 会创建临时表、逐行拷贝、全程锁表
-- 5.7 默认加索引可能走 COPY 或 INPLACE，显式指定 COPY 模拟最差情况
-- COPY 模式下：表级独占锁，DDL 期间不允许任何 DML（读写均阻塞）
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id), ALGORITHM=COPY;
```

### DDL 执行过程

`ALGORITHM=COPY` 是最原始的 DDL 方式，执行流程如下：

```
1. 创建 tmp_table（带新索引结构的临时表）
2. 对原表加表级独占锁（LOCK=SHARED，期间阻塞所有 DML）
3. 逐行从原表拷贝数据到 tmp_table
4. 用 tmp_table 替换原表
5. 释放锁
```

### 为什么慢

| 维度 | COPY 模式 | 影响 |
|------|-----------|------|
| 锁级别 | 表级独占锁 | DDL 期间所有 DML 阻塞（INSERT/UPDATE/DELETE 全部等待） |
| 数据拷贝 | 全表逐行拷贝到临时表 | 20 万行需完整拷贝，I/O 和 CPU 开销大 |
| 磁盘空间 | 需要 2 倍表空间 | 原表 + 临时表同时存在 |
| 执行时间 | 与表行数成正比 | 表越大越慢，百万行表可达分钟级 |
| 元数据锁 (MDL) | 长时间持锁 | 可能导致后续查询排队堆积 |

核心问题有四点：

1. **全程锁表**：从开始到结束，原表不允许任何写操作（甚至部分读操作也受限）
2. **全量拷贝**：需要在存储引擎外创建临时表，逐行 `INSERT ... SELECT` 拷贝
3. **大表灾难**：表越大，拷贝时间越长，锁表时间越长。生产环境百万行表可达数十分钟
4. **主从延迟**：如果主库 DDL 耗时 10 分钟，从库也要同样时间，期间从库数据严重滞后

20 万行数据下，COPY 模式加索引耗时约 **3-5 秒**（取决于硬件），期间表完全不可写。生产环境百万行表可达 **分钟级甚至十分钟级锁表**。

::: tip 核心认知
`ALGORITHM=COPY` 把加索引变成了"重建整张表"。索引只是顺带建的，真正耗时的是全表拷贝。锁表不是加索引的代价，而是 COPY 算法的代价。
:::

## 优化方案

### good.sql

```sql
-- Online DDL 方式：ALGORITHM=INPLACE, LOCK=NONE
-- INPLACE 模式在存储引擎内部完成索引构建，不创建临时表
-- LOCK=NONE 允许 DDL 期间并发执行 DML（INSERT/UPDATE/DELETE 不阻塞）
-- 8.0 中部分操作可进一步用 ALGORITHM=INSTANT（元数据级变更，瞬间完成）
-- 注意：加索引不支持 INSTANT，但 INPLACE+LOCK=NONE 已是最佳实践
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id), ALGORITHM=INPLACE, LOCK=NONE;
```

### 原理

`ALGORITHM=INPLACE, LOCK=NONE` 的执行流程完全不同：

```
1. 短暂获取 MDL 排他锁（仅元数据变更瞬间，毫秒级）
2. 降级为 MDL 共享锁，允许并发 DML
3. 在存储引擎内部构建索引（row log 记录期间 DML 变更）
4. 回放 row log，合并到新索引
5. 短暂获取 MDL 排他锁，提交变更
```

核心原理：

1. **不创建临时表**：索引在 InnoDB 内部直接构建，无需拷贝全表数据
2. **row log 机制**：DDL 期间并发的 DML 操作记录到 row log，DDL 完成后回放合并
3. **LOCK=NONE**：DDL 期间允许 INSERT/UPDATE/DELETE 并发执行，业务不感知
4. **MDL 锁持有极短**：仅在开始和提交阶段持有排他 MDL 锁，中间降级为共享锁

::: tip 显式声明的好处
用 `ALGORITHM=INPLACE, LOCK=NONE` 显式声明，MySQL 会先校验是否支持。如果不支持，**直接报错而非静默退化到 COPY**--这比"以为没锁表、实际锁了半小时"安全得多。
:::

### 三种 DDL 算法对比

| 算法 | 数据拷贝 | 锁 | 并发 DML | 适用场景 |
|------|----------|-----|----------|----------|
| COPY | 全表拷贝到临时表 | 表级独占 | 不允许 | 兼容性兜底（最差） |
| INPLACE | 存储引擎内部构建 | NONE/SHARED | 允许 | 加索引、加列等（推荐） |
| INSTANT | 不拷贝 | 无 | 允许 | 加列、重命名列等（8.0 新增，最快） |

> 注意：**加索引**操作不支持 INSTANT（需要实际构建索引数据），但 INPLACE+LOCK=NONE 已是最佳方案。INSTANT 适用于 `ADD COLUMN`（末尾加列）等纯元数据变更。

<ExplainCompare
  :bad="{ algorithm: 'COPY', 锁级别: '表级独占锁', 拷贝方式: '全表逐行拷贝到临时表', 并发DML: '阻塞', 耗时: '3-5s（20万行）' }"
  :good="{ algorithm: 'INPLACE + LOCK=NONE', 锁级别: '毫秒级 MDL', 拷贝方式: '存储引擎内部构建索引', 并发DML: '允许', 耗时: '1-2s（20万行）' }"
  improvement="锁表时间从全程降到毫秒级，业务零感知，执行耗时约提升 2 倍"
/>

## 量化对比

| 指标 | bad (COPY) | good (INPLACE+NONE) | 提升 |
|------|-----------|---------------------|------|
| 锁表时间 | 全程（3-5 秒） | 毫秒级 | **业务零感知** |
| 执行耗时 | 3-5 秒 | 1-2 秒 | **约 2 倍** |
| 磁盘空间 | 2x 表空间 | 1x + 索引 | **节省 ~50%** |
| 并发 DML | 阻塞 | 不阻塞 | **在线无停机** |
| 主从延迟 | 分钟级 | 秒级 | **可控** |

## 避坑指南

::: warning 注意事项

1. **先评估再执行**：用 `ALGORITHM=INPLACE, LOCK=NONE` 语法让 MySQL 自行校验，不支持会直接报错而非静默退化到 COPY。

2. **监控 row log 大小**：并发 DML 过多时 row log 可能膨胀，需关注 `innodb_online_alter_log_max_size`（默认 128MB）。row log 满了 DDL 会失败回滚。

3. **大表仍需谨慎**：INPLACE 虽然不锁表，但构建索引仍消耗 CPU 和 I/O，建议低峰期执行。

4. **使用 pt-online-schema-change**：超大规模表（亿级）可考虑 pt-osc 或 gh-ost 工具做更细粒度控制，它们通过触发器/binlog 在应用层模拟 Online DDL，可控性更强。

5. **不要省略 LOCK 子句**：只写 `ALGORITHM=INPLACE` 而不写 `LOCK=NONE`，MySQL 可能选择 `LOCK=SHARED`（允许读、阻塞写）。显式写 `LOCK=NONE` 才能确保写不阻塞。

6. **先在从库验证**：生产环境先在从库执行 DDL，观察耗时和影响，确认无误再在主库执行。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| INPLACE + LOCK=NONE 加索引 | ✅ 支持 | ✅ 支持 |
| INSTANT 算法 | ❌ 无此能力 | ✅ 加列等操作瞬间完成 |
| Online DDL 覆盖范围 | 部分操作仍退化为 COPY | 覆盖更广，退化更少 |
| 修改列类型 | 多数退化为 COPY | 更多场景支持 INPLACE |
| DDL 日志 | row log | row log（机制一致） |

::: tip 8.0 INSTANT 算法
8.0.12 引入 INSTANT 算法，加列（末尾）、重命名列等纯元数据变更可**瞬间完成**，不拷贝任何数据。但加索引需要实际构建 B+ 树，不支持 INSTANT，仍用 INPLACE。

```sql
-- 8.0 末尾加列，瞬间完成（毫秒级）
ALTER TABLE t_big_table ADD COLUMN remark VARCHAR(100), ALGORITHM=INSTANT;
```
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 42-online-ddl

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 42-online-ddl --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 42-online-ddl --no-seed
```
