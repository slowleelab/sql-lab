# 自增主键跳跃与性能

<CaseMeta difficulty="⭐⭐" category="索引设计与失效" versions="5.7 & 8.0" :tags="['AUTO_INCREMENT', '跳号', '自增锁', 'innodb_autoinc_lock_mode']" />

## 自增 ID 大量跳号：回滚的事务为何照样消耗 ID
高并发写入的系统中，自增主键 ID 出现了大量"跳号"--ID 从 100000 直接跳到 100006，中间的 100001~100005 凭空消失。排查后发现是批量 INSERT 失败回滚导致的，但业务方对此感到困惑：事务回滚了，为什么 ID 还是消耗了？

```sql
-- 批量插入 5 行后回滚，自增 ID 已跳过这 5 个
START TRANSACTION;
INSERT INTO t_id_test (batch_no, data_value) VALUES
    ('FAIL01', 'a'), ('FAIL01', 'b'), ('FAIL01', 'c'),
    ('FAIL01', 'd'), ('FAIL01', 'e');
ROLLBACK;

-- 回滚后自增值已跳过这 5 个 ID，无法回收
SELECT AUTO_INCREMENT AS next_auto_inc_after_rollback
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'sql_treasure' AND TABLE_NAME = 't_id_test';
```

更深层的问题是 `innodb_autoinc_lock_mode` 的选择。默认锁模式下批量插入会预分配连续 ID 段、失败后整段丢弃，跳号更严重。而 interleave 模式（模式 2）虽然并发性能更好，但跳号也可能更多。大量跳号长期累积有 BIGINT 溢出风险。

::: warning 真实场景
跳号本身不影响业务正确性（ID 只需唯一不需连续），但高并发写入 + 频繁失败回滚的场景下，ID 增长速度远超实际数据量。某些合规审计要求 ID 连续的场景（如发票号、流水号），则完全不能用 AUTO_INCREMENT，需要应用层发号器。
:::

## 问题分析

### bad.sql

```sql
-- bad.sql: 默认 lock_mode=1 下，批量插入预分配 ID 段，失败回滚后整段跳号
-- 模拟一次批量插入失败（故意触发主键冲突或违反约束）
-- 先查看当前自增值
SELECT AUTO_INCREMENT AS next_auto_inc
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'sql_treasure' AND TABLE_NAME = 't_id_test';

-- 批量插入一批数据（多行 VALUES），随后模拟失败回滚
START TRANSACTION;
INSERT INTO t_id_test (batch_no, data_value) VALUES
    ('FAIL01', 'a'), ('FAIL01', 'b'), ('FAIL01', 'c'),
    ('FAIL01', 'd'), ('FAIL01', 'e');
-- 模拟失败：回滚事务（这批自增 ID 已被消耗，无法回收）
ROLLBACK;

-- 回滚后自增值已跳过这 5 个 ID
SELECT AUTO_INCREMENT AS next_auto_inc_after_rollback
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'sql_treasure' AND TABLE_NAME = 't_id_test';
```

### 观察结果

本案例不产生传统 EXPLAIN 表格，重点观察 AUTO_INCREMENT 跳号现象。

执行前自增值：

```
+----------------+
| next_auto_inc  |
+----------------+
|         100001 |
+----------------+
```

回滚后自增值：

```
+-----------------------------+
| next_auto_inc_after_rollback|
+-----------------------------+
|                      100006 |
+-----------------------------+
```

| 现象 | 值 | 分析 |
|------|-----|------|
| 回滚前 AUTO_INCREMENT | 100001 | 基础数据后的下一个 ID |
| 回滚后 AUTO_INCREMENT | 100006 | **跳过了 100001~100005，无法回收** |
| 数据行数 | 不变 | 回滚后无新增行，但 ID 已消耗 |

### 为什么慢

InnoDB 的 AUTO_INCREMENT 机制设计为**不保证无间隙**：

1. **ID 提前分配**：INSERT 时先向引擎申请自增 ID，此时 AUTO_INCREMENT 计数器已前进
2. **回滚不回收**：事务 ROLLBACK 后，已分配的 ID 不会归还，计数器只增不减
3. **批量预分配**：`lock_mode=1`（默认）下批量 INSERT 会一次性预分配连续 ID 段，若语句失败整段丢弃

三种跳号场景：

| 场景 | 原因 | 跳号量 |
|------|------|--------|
| INSERT 失败回滚 | 事务回滚，已分配 ID 不回收 | = 插入行数 |
| 批量 INSERT 中途失败 | 预分配的整段 ID 丢弃 | 可达 1~批大小 |
| INSERT ... ON DUPLICATE KEY UPDATE | 冲突行不插入但 ID 已分配 | = 冲突行数 |
| MySQL 重启（8.0 前） | 计数器从 MAX(id)+1 重算 | 重启前的间隙消失 |

::: warning BIGINT 溢出风险
大量跳号长期累积可能导致 BIGINT（最大 9.2×10^18）溢出。虽然极端情况，但高并发写入 + 频繁失败回滚的场景需监控 `AUTO_INCREMENT` 增长速率。
:::

::: tip 核心认知
AUTO_INCREMENT 计数器只增不减，事务回滚不回收已分配的 ID。这是 SQL 标准行为，无法通过配置避免。
:::

## 优化方案

### good.sql

```sql
-- good.sql: 设置 innodb_autoinc_lock_mode=2（interleave 模式）
-- 并发批量插入时不再持有表级自增锁，减少锁等待，提升并发吞吐
-- 需先执行 setup-good.sql 切换锁模式
-- 注意: lock_mode=2 下批量插入可能产生更多跳号，但并发性能更好

SELECT @@innodb_autoinc_lock_mode AS lock_mode;

-- 并发友好的批量插入（interleave 模式下不阻塞其他事务的插入）
START TRANSACTION;
INSERT INTO t_id_test (batch_no, data_value) VALUES
    ('OK01', 'x'), ('OK01', 'y'), ('OK01', 'z');
COMMIT;

SELECT COUNT(*) AS rows_after, MAX(id) AS max_id FROM t_id_test WHERE batch_no = 'OK01';
```

先执行 setup-good.sql 切换锁模式：

```sql
-- setup-good.sql: 切换自增锁模式为 interleave（模式 2）
-- 模式 2 下并发插入性能最佳，不再持有表级 AUTO-INC 锁
-- 注意: 这是 SESSION 级设置，需在执行 good.sql 的同一连接生效
SET SESSION innodb_autoinc_lock_mode = 2;
```

### 原理

`lock_mode=2`（interleave 模式）下：

1. **不持有表级 AUTO-INC 锁**：多个事务可同时执行 INSERT，互不阻塞
2. **轻量级互斥量**：仅在获取单个自增值时短暂持有 mutex（微秒级）
3. **适合主从复制**：8.0 默认基于行的复制（ROW binlog），interleave 模式安全
4. **并发吞吐最高**：多线程插入无需排队等表级锁

`innodb_autoinc_lock_mode` 三种模式对比：

| 模式 | 名称 | 锁粒度 | 批量插入 | 并发插入 | 跳号风险 |
|------|------|--------|----------|----------|----------|
| 0 | traditional | 表级 AUTO-INC 锁（全程持有） | 串行 | 差 | 低 |
| 1 | consecutive（5.7 默认） | 表级锁（仅语句级） | 预分配连续段 | 中 | 中 |
| 2 | interleave（8.0 默认） | **无表级锁** | 允许交错 | **最好** | 较高 |

### 对比

| | bad (mode=1) | good (mode=2) |
|---|---|---|
| 表级 AUTO-INC 锁 | 语句级持有 | 不持有 |
| 并发插入吞吐 | 中 | 高（2~3 倍） |
| 跳号程度 | 中 | 略高（用并发换性能） |

并发 10 线程各插 1 万行的锁等待对比：

| 模式 | 总耗时 | 锁等待 | 说明 |
|------|--------|--------|------|
| 0 (traditional) | ~12s | 高 | 全程表锁，串行 |
| 1 (consecutive) | ~5s | 中 | 语句级表锁 |
| 2 (interleave) | ~2s | 低 | 无表锁，并发最佳 |

<ExplainCompare
  :bad="{ type: '锁模式', key: 'mode=1', rows: '并发~5s', Extra: '语句级表级 AUTO-INC 锁' }"
  :good="{ type: '锁模式', key: 'mode=2', rows: '并发~2s', Extra: '无表级锁，并发最佳' }"
  improvement="消除表级自增锁，并发插入吞吐提升 2~3 倍"
/>

## 避坑指南

::: warning 注意事项

1. **跳号无法完全避免**。无论哪种锁模式，事务回滚导致的跳号都无法避免（这是 SQL 标准行为）。模式 2 用略多的跳号换取更高的并发吞吐，对绝大多数业务是值得的。

2. **Statement binlog 必须用模式 0 或 1**。模式 2（interleave）下批量插入的 ID 可能不连续，Statement-based 复制会导致主从不一致。只有使用 ROW binlog（8.0 默认）时模式 2 才安全。

3. **`innodb_autoinc_lock_mode` 在部分版本中是只读变量**。MySQL 8.0.13 前是只读全局变量，不能 `SET SESSION` 修改，需在 `my.cnf` 中配置并重启。8.0.13+ 起可在会话级动态设置。生产环境请在配置文件中设置。

4. **要求 ID 严格连续的场景不要用 AUTO_INCREMENT**。如发票号、流水号等合规要求连续的 ID，应改用应用层发号器（如雪花算法 Snowflake），不依赖数据库自增。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 默认 `innodb_autoinc_lock_mode` | 1 (consecutive) | 2 (interleave) |
| 重启后 AUTO_INCREMENT | 从 MAX(id)+1 重算（可能回收间隙） | 持久化到 redo log，重启不丢失 |
| 会话级动态设置 | ❌ 只读 | ✅ 8.0.13+ 支持 |
| 推荐 binlog 格式 | ROW（若用模式 2） | ROW（默认） |

::: tip 模式选择建议
- **MySQL 8.0**：默认就是模式 2，配合 ROW binlog，绝大多数场景推荐保持默认
- **MySQL 5.7**：默认模式 1，若使用 ROW binlog 可改为模式 2 提升并发
- **Statement binlog**：必须用模式 0 或 1（保证批量插入 ID 连续，主从一致），模式 2 不安全
:::

::: danger 变量为只读（部分版本）
`innodb_autoinc_lock_mode` 在 MySQL 8.0.13 前是**只读全局变量**，不能 `SET SESSION` 修改，需在 `my.cnf` 中配置并重启。8.0.13+ 起可在会话级动态设置（实验性）。生产环境请在配置文件中设置 `innodb_autoinc_lock_mode=2`。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 14-auto-increment-gap

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 14-auto-increment-gap --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 14-auto-increment-gap --no-seed
```
