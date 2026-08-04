# 修改字段类型的锁行为差异

<CaseMeta difficulty="⭐⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['MODIFY COLUMN', 'Online DDL', 'ALGORITHM', 'LOCK', '锁表']" />

## 100 万：实际手机号只有 11 位
DBA 发现用户表的 `phone` 字段定义成了 `VARCHAR(50)`，实际手机号只有 11 位，需要改成 `VARCHAR(20)` 节省空间。表有 100 万行数据，他直接执行：

```sql
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '手机号';
```

这条 DDL 跑了 **90 秒**，期间所有 INSERT/UPDATE/DELETE 全部排队等待，业务写入完全停滞，连接池被打满，监控告警一片飘红。

问题出在哪？不是修改列类型本身慢，而是**没有显式指定 `ALGORITHM` 和 `LOCK`**——MySQL 自行选择了 `LOCK=SHARED`，期间阻塞所有写操作。

::: warning 真实场景
"以为很快结果锁了 10 分钟"是 DDL 领域最常见的生产事故。很多 DBA 知道 Online DDL 的存在，但忽略了显式指定 `ALGORITHM` 和 `LOCK` 的重要性。不指定时 MySQL 的默认行为不可控，不同版本、不同配置下可能完全不同。
:::

## 问题分析

### bad.sql

```sql
-- 不指定 ALGORITHM 和 LOCK，让 MySQL 自行选择
-- 5.7 中修改列类型（VARCHAR(50) -> VARCHAR(20)）属于 rebuild 操作
-- 如果不显式指定 LOCK=NONE，MySQL 可能选择 LOCK=SHARED 甚至 COPY
-- LOCK=SHARED 期间: 允许读但阻塞所有写操作（INSERT/UPDATE/DELETE 排队）
-- 100 万行重建期间，业务写入完全停滞
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '手机号';
```

### DDL 执行过程

不指定 `ALGORITHM` 和 `LOCK` 时，MySQL 的决策过程：

```
1. 判断 MODIFY COLUMN 是否支持 INPLACE -> 支持（但需 rebuild）
2. 选择 LOCK 级别 -> 默认 LOCK=DEFAULT（可能退化为 SHARED）
3. LOCK=SHARED 意味着: 允许 SELECT，阻塞 INSERT/UPDATE/DELETE
4. 开始重建表数据（100 万行逐行转换）
5. 重建期间所有写操作排队等待
```

### 为什么慢

| 维度 | 不指定策略 (bad) | 影响 |
|------|-----------------|------|
| 锁级别 | LOCK=SHARED（默认） | **阻塞所有写操作**，读不受影响 |
| 数据拷贝 | 全表 rebuild | 100 万行逐行转换列类型 |
| 执行时间 | 与表行数成正比 | 100 万行约 60-120 秒 |
| 写操作 | 完全阻塞 | 期间 INSERT/UPDATE/DELETE 排队 |
| 不可控性 | MySQL 自行选择 | 不同版本/配置行为可能不同 |

核心问题：

1. **LOCK=SHARED 阻塞写入**：MySQL 默认可能选择 SHARED 锁，期间所有 INSERT/UPDATE/DELETE 排队等待，业务写入完全停滞
2. **全表 rebuild**：修改列类型需要重建每一行的记录格式，100 万行逐行转换
3. **行为不可预测**：不同 MySQL 版本、不同参数配置下，默认行为可能不同。5.7 和 8.0 的默认策略有差异
4. **静默退化风险**：如果 INPLACE 不支持当前操作，MySQL 可能静默退化到 COPY 模式（全程锁表），而你毫不知情
5. **生产事故隐患**："以为很快结果锁了 10 分钟"是常见的生产事故原因

```
不同 LOCK 级别对比:

LOCK=NONE:       读写均不阻塞（最优）
LOCK=SHARED:     读不阻塞，写阻塞（默认可能选这个）
LOCK=EXCLUSIVE:  读写均阻塞（最差，COPY 模式）
```

::: tip 核心认知
不指定 `ALGORITHM` 和 `LOCK` 的风险不在于"一定慢"，而在于**行为不可控**。你可能在测试环境很快（MySQL 恰好选了 LOCK=NONE），到生产环境就锁表（MySQL 选了 LOCK=SHARED）。显式指定让行为从"看运气"变成"可预测"。
:::

## 优化方案

### good.sql

```sql
-- 显式指定 ALGORITHM=INPLACE, LOCK=NONE
-- INPLACE 在存储引擎内部完成重建，不创建临时表
-- LOCK=NONE 允许 DDL 期间并发执行 DML（读写均不阻塞）
-- 原理: row log 记录 DDL 期间的 DML 变更，完成后回放合并
-- 注意: 如果指定了 LOCK=NONE 但操作不支持，MySQL 会直接报错而非静默退化
--       这样可以避免"以为不锁表实际锁了"的生产事故
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '手机号', ALGORITHM=INPLACE, LOCK=NONE;
```

### 原理

`ALGORITHM=INPLACE, LOCK=NONE` 的执行流程：

```
1. 校验: INPLACE+LOCK=NONE 是否支持当前操作 -> 支持则继续，不支持则报错
2. 短暂获取 MDL 排他锁（毫秒级）
3. 降级为 MDL 共享锁，允许并发 DML
4. 在 InnoDB 内部重建表数据（row log 记录期间 DML 变更）
5. 回放 row log，合并并发变更
6. 短暂获取 MDL 排他锁，提交变更
```

核心价值不在于"更快"，而在于**"不锁表"**：

1. **LOCK=NONE 允许并发 DML**：DDL 期间 INSERT/UPDATE/DELETE 正常执行，业务完全无感知
2. **row log 机制**：DDL 期间的并发 DML 变更记录到 row log，DDL 完成后回放合并，保证数据一致性
3. **显式指定防退化**：如果操作不支持 LOCK=NONE，MySQL 直接报错 `LOCK=NONE is not supported`，而非静默退化为 SHARED 或 EXCLUSIVE
4. **MDL 锁极短**：仅在开始和提交阶段持有排他 MDL 锁，中间降级为共享锁

```
不指定（危险）:
  ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20);
  -> MySQL 自行选择，可能 LOCK=SHARED
  -> 写操作阻塞 60-120 秒
  -> 你以为没问题，实际业务写入停了 2 分钟

显式指定（安全）:
  ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20), ALGORITHM=INPLACE, LOCK=NONE;
  -> 如果支持: 读写均不阻塞，业务无感知
  -> 如果不支持: 直接报错，你知道需要换方案
  -> 不存在"以为不锁实际锁了"的情况
```

### 对比

| | bad.sql (不指定) | good.sql (INPLACE+NONE) |
|---|---|---|
| 锁级别 | SHARED（阻塞写） | **NONE（读写均不阻塞）** |
| 行为可预测性 | MySQL 自行选择 | **显式指定，不支持则报错** |
| 写操作阻塞 | 60-120 秒 | **0 秒** |
| 执行耗时 | 60-120 秒 | 60-120 秒（相当） |
| 静默退化风险 | 有 | **无（不支持则报错）** |

<ExplainCompare
  :bad="{ algorithm: 'INPLACE（默认）', 锁级别: 'LOCK=SHARED（阻塞写）', 写操作: '阻塞 60-120s', 行为可预测性: '低（依赖默认）', 静默退化: '有' }"
  :good="{ algorithm: 'INPLACE + LOCK=NONE', 锁级别: 'LOCK=NONE（读写均不阻塞）', 写操作: '不阻塞', 行为可预测性: '高（显式指定）', 静默退化: '无（不支持则报错）' }"
  improvement="写操作阻塞从 60-120 秒降到 0 秒，业务零感知，且行为完全可预测"
/>

### 常见列类型修改的算法支持

| 修改操作 | INPLACE | LOCK=NONE | 说明 |
|----------|---------|-----------|------|
| VARCHAR 变长（50->100） | ✅ 支持 | ✅ 支持 | 8.0 中扩大 VARCHAR 通常 INPLACE |
| VARCHAR 变短（50->20） | ✅ 支持 | ✅ 支持 | 需 rebuild 但可 LOCK=NONE |
| INT -> BIGINT | ✅ 支持 | ✅ 支持 | 需 rebuild 但可 LOCK=NONE |
| 改列字符集 | ✅ 支持 | ✅ 支持 | 需 rebuild 但可 LOCK=NONE |
| 改列类型为完全不同类型 | ⚠️ 可能不支持 | ⚠️ 可能不支持 | 如 VARCHAR -> INT，可能需 COPY |

## 避坑指南

::: warning 注意事项

1. **永远显式指定 ALGORITHM 和 LOCK**：不要依赖 MySQL 的默认行为，显式指定让行为可预测。不支持会直接报错，不会静默退化。

2. **先在测试环境验证**：用相同数据量在测试环境执行，确认耗时和锁行为。测试环境快不代表生产环境快（数据量、并发量不同）。

3. **监控 row log 大小**：并发 DML 过多时 row log 可能膨胀，关注 `innodb_online_alter_log_max_size`（默认 128MB）。row log 满了 DDL 会失败回滚。

4. **低峰期执行**：虽然 LOCK=NONE 不阻塞业务，但 rebuild 仍消耗 CPU 和 I/O，建议低峰期执行。

5. **超大表考虑 pt-osc**：亿级表可考虑 pt-online-schema-change 或 gh-ost，提供更细粒度的控制（暂停、限速、进度监控）。

6. **不要只写 ALGORITHM 不写 LOCK**：只写 `ALGORITHM=INPLACE` 而不写 `LOCK=NONE`，MySQL 可能选择 `LOCK=SHARED`。两个都要显式写。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| INPLACE + LOCK=NONE 修改列类型 | ✅ 支持 | ✅ 支持 |
| Online DDL 覆盖范围 | 部分操作退化为 COPY | 覆盖更广，退化更少 |
| 默认 LOCK 级别 | 更容易退化为 SHARED | 更友好，倾向 NONE |
| 代价模型 | 一般 | 更精确 |
| 核心建议 | **始终显式指定 ALGORITHM 和 LOCK** | **始终显式指定 ALGORITHM 和 LOCK** |

::: tip 核心建议一致
两个版本都支持 INPLACE+LOCK=NONE 修改列类型，核心建议完全一致：**永远显式指定 ALGORITHM 和 LOCK**。8.0 的 Online DDL 覆盖范围更广，默认行为更友好，但"显式指定"的原则不变——这是避免生产事故的最后一道防线。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 49-modify-column-type

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 49-modify-column-type --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 49-modify-column-type --no-seed
```
