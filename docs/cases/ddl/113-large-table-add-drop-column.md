# 大表增删列：INSTANT 与 Online DDL 操作全解

<CaseMeta difficulty="⭐⭐⭐" category="DDL 与大表" versions="5.7 & 8.0" :tags="['ADD COLUMN', 'DROP COLUMN', 'INSTANT', 'Online DDL', 'ALGORITHM', '锁表']" />

## 删一个废弃列锁表 12 分钟：大表增删列的 INSTANT 操作矩阵
线上订单表已经积累了 3000 万行数据。一次需求重构要删掉废弃字段 `legacy_memo`，再加两个业务跟踪字段。DBA 在 MySQL 5.7 上执行：

```sql
ALTER TABLE t_order
  DROP COLUMN legacy_memo,
  ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web' COMMENT '下单渠道' AFTER status,
  ADD COLUMN is_vip TINYINT NOT NULL DEFAULT 0 COMMENT '是否 VIP';
```

这条 DDL 跑了 **12 分钟**，期间整张表被逐行重建，订单写入大量超时，监控告警一片飘红。加列慢可以理解，**删一个列为什么也要重建整张表？**

这就是 **"大表增删列"** 的核心痛点——在 MySQL 5.7 中，加列和删列虽然支持 `ALGORITHM=INPLACE`，但本质上都是 **rebuild 操作**：创建新表、逐行拷贝、时间与行数成正比。而 MySQL 8.0 的 `INSTANT` 算法把增删列逐步变成了**纯元数据操作**，毫秒级完成。

::: warning 真实场景
业务迭代中"加字段"是最高频的 DDL：下单渠道、标记位、扩展属性。删字段相对少见，但字段重构、表瘦身时必然遇到。5.7 时代每次增删列都是一次"低峰期小型手术"，8.0 后这类操作基本不再需要停机窗口。
:::

## 问题分析

### bad.sql — 5.7 上的增删列

```sql
-- MySQL 5.7: ADD COLUMN / DROP COLUMN 都是 INPLACE rebuild
-- 中间位置加列（AFTER）、删列均需重建整张表
-- 执行过程: 建临时表 -> 逐行拷贝（去掉/插入目标列）-> 重命名替换
-- 3000 万行约需 10-15 分钟，拷贝期间允许并发 DML，但 MDL 锁在起止阶段排他
ALTER TABLE t_order
  DROP COLUMN legacy_memo,
  ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web' AFTER status;
```

### DDL 执行过程

5.7 的增删列走的是 **INPLACE rebuild** 路径：

```
1. 获取 MDL 排他锁
2. 在存储引擎内部创建带新结构的临时表（不经过 Server 层，所以叫 INPLACE）
3. 逐行从原表拷贝数据：加列则写入默认值，删列则丢弃该列
4. 通过 row log 回放拷贝期间的 DML 变更
5. 再次获取 MDL 排他锁，重命名替换原表
6. 释放锁
```

### 为什么慢

| 维度 | 5.7 增删列（INPLACE rebuild） | 影响 |
|------|------------------------------|------|
| 数据拷贝 | 全表逐行重建 | 3000 万行完整拷贝，I/O 和 CPU 开销大 |
| 磁盘空间 | 需要约 1 倍额外表空间 | 原表与新表短期共存 |
| 执行时间 | 与表行数成正比 | 百万行分钟级，千万行十分钟级 |
| MDL 锁 | 起止阶段排他 | 高并发下业务查询排队堆积 |
| 主从延迟 | 从库同样重建 | 主库 12 分钟，从库也滞后 12 分钟 |

::: tip 核心认知
5.7 删列慢的本质不是"删除"这个动作慢，而是**记录的物理格式变了**：列删掉后，每条记录都要重新编排后写到新表，这等价于一次全表重建。加列同理——默认值要逐行写进记录。
:::

### 增删列算法支持矩阵（关键表）

| 操作 | MySQL 5.7 | 8.0.12 – 8.0.28 | 8.0.29+ |
|------|-----------|-----------------|---------|
| 末尾加列 | INPLACE 重建 | **INSTANT** | **INSTANT** |
| 中间加列（AFTER/BEFORE） | INPLACE 重建 | INPLACE 重建 | **INSTANT** |
| 删列 DROP COLUMN | INPLACE 重建 | INPLACE 重建 | **INSTANT** |
| 重命名列 RENAME COLUMN | CHANGE 重建 | **INSTANT** | **INSTANT** |
| 修改列默认值 | 元数据操作 | **INSTANT** | **INSTANT** |
| 修改列类型 MODIFY | COPY/重建 | INPLACE 重建 | INPLACE 重建 |

> 注意：8.0.12 首次引入 INSTANT 时只支持**末尾加列**等少数操作；8.0.29 采用了新的行格式实现（WL#14723），才支持删列和任意位置加列的 INSTANT。

## 优化方案

### good.sql — MySQL 8.0.29+

```sql
-- 8.0.29+：增列、删列全部 ALGORITHM=INSTANT
-- 只修改数据字典元数据，不拷贝任何行，3000 万行也是毫秒级
ALTER TABLE t_order
  DROP COLUMN legacy_memo,
  ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web' AFTER status,
  ADD COLUMN is_vip TINYINT NOT NULL DEFAULT 0,
  ALGORITHM=INSTANT;
```

### good.sql — 8.0.12 – 8.0.28（拆分操作）

```sql
-- 这个版本区间：末尾加列是 INSTANT，删列和中间加列仍要重建
-- 把"能 INSTANT 的"和"必须重建的"拆成两条语句，避免加列白白陪跑重建

-- 1) 末尾加列：INSTANT，毫秒级
ALTER TABLE t_order
  ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web',
  ADD COLUMN is_vip TINYINT NOT NULL DEFAULT 0,
  ALGORITHM=INSTANT;

-- 2) 删列：INPLACE rebuild，低峰期执行；必须放在中间位置的列同理
ALTER TABLE t_order DROP COLUMN legacy_memo, ALGORITHM=INPLACE, LOCK=NONE;
```

### good.sql — MySQL 5.7

```sql
-- 5.7 没有 INSTANT，两种选择：

-- 方式 1: 显式 INPLACE + LOCK=NONE（不阻塞 DML，但仍重建，耗时长）
ALTER TABLE t_order
  DROP COLUMN legacy_memo,
  ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web',
  ALGORITHM=INPLACE, LOCK=NONE;

-- 方式 2: pt-online-schema-change / gh-ost（触发器或 binlog 同步，可控性更强）
pt-online-schema-change --alter "DROP COLUMN legacy_memo, ADD COLUMN channel VARCHAR(20) NOT NULL DEFAULT 'web'" \
  D=sql_treasure,t=t_order --execute
```

### 原理

`ALGORITHM=INSTANT` 只动数据字典：

```
传统 rebuild (5.7):
  每条记录: [id][order_no][user_id][status][legacy_memo][amount]
  删列后:   逐行重写为 [id][order_no][user_id][status][amount] -> 全表重建

INSTANT (8.0.29+):
  行记录:   原样不动
  数据字典: 记录"legacy_memo 已删除""channel 默认值 'web'"
  查询时:   按新元数据解析记录，被删列直接跳过，新列取默认值返回
```

核心要点：

1. **只改元数据**：列的增删定义写入数据字典，表数据文件不动，耗时与表大小无关
2. **默认值动态返回**：新列默认值存在元数据里，查询时动态补到结果上，无需逐行填充
3. **显式声明即探路**：带上 `ALGORITHM=INSTANT` 后，只要有一个操作不支持，MySQL **直接报错而不是静默退化到重建**

<ExplainCompare
  :bad="{ algorithm: '5.7 INPLACE rebuild', 数据拷贝: '全表逐行重建', 三千万行耗时: '10-15 分钟', 磁盘空间: '~1x 额外空间', 业务影响: 'MDL 锁 + 写入超时' }"
  :good="{ algorithm: '8.0.29 INSTANT', 数据拷贝: '不拷贝', 三千万行耗时: '~10 毫秒', 磁盘空间: '0 额外', 业务影响: '零感知' }"
  improvement="增删列从 12 分钟重建降到 10 毫秒元数据变更，提升数万倍，且与表大小无关"
/>

## 量化对比

以 **3000 万行**订单表为例：

| 指标 | bad（5.7 rebuild） | good（8.0.29 INSTANT） | 提升 |
|------|--------------------|-----------------------|------|
| 执行耗时 | 10-15 分钟 | 毫秒级 | **数万倍** |
| 数据拷贝 | 全表 3000 万行 | 0 行 | **不触碰数据** |
| 额外磁盘空间 | ~1x 表空间 | 0 | — |
| 并发 DML | 起止阶段阻塞 | 完全不阻塞 | **在线零感知** |
| 主从延迟 | 十分钟级 | 毫秒级 | **可控** |

## 避坑指南

::: warning 注意事项

1. **显式写 `ALGORITHM=INSTANT`**：不支持时直接报错，杜绝"以为秒完成、实际重建了十几分钟"。

2. **一条 ALTER 里混合操作要小心**：只要其中一个操作不支持 INSTANT，整条语句都会重建。8.0.29 之前应把"末尾加列"与"删列/中间加列"拆成多条语句。

3. **8.0.29 之前有 INSTANT 列数量上限**：同一张表最多累积 64 个 INSTANT 加列，超限会报错要求重建表；用 `OPTIMIZE TABLE` 重建后计数清零。8.0.29 新行格式已取消该限制。

4. **删列不会立即释放磁盘空间**：即使 INSTANT 删除，列数据在物理记录中要等到后续行更新或表重建时才回收；想主动收缩仍需 `OPTIMIZE TABLE`（操作本身会重建大表，需低峰执行）。

5. **删列前排查依赖**：该列上有索引或外键时 MySQL 会直接拒绝，需先删索引/外键；同时检查视图、存储过程、触发器和应用 ORM 映射，避免删完才发现线上报错。

6. **5.7 用 pt-osc / gh-ost 兜底**：无法升级 8.0 时，用在线变更工具控制拷贝节奏，避免长时间 MDL 锁堆积。

7. **先在从库验证**：确认执行路径和耗时后再上主库，并安排在业务低峰期。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0.12 – 8.0.28 | 8.0.29+ |
|------|-----|-----------------|---------|
| 末尾加列 | INPLACE 重建 | INSTANT | INSTANT |
| 任意位置加列 | INPLACE 重建 | INPLACE 重建 | INSTANT |
| 删列 | INPLACE 重建 | INPLACE 重建 | INSTANT |
| INSTANT 列数量限制 | — | 64 个，需定期重建 | 无限制 |
| 显式 LOCK=NONE | ✅ 支持 | ✅ 支持 | ✅ 支持 |

::: tip 8.0.29 是增删列体验的分水岭
8.0.12 让"末尾加列"秒完成，8.0.29 把删列和任意位置加列也纳入 INSTANT 并取消数量上限。如果大表增删列频繁，8.0.29 之后的版本才是真正"不看黄历随时改"。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 113-large-table-add-drop-column

# 在 MySQL 5.7 上运行（对比重建耗时）
./scripts/run-case.sh 113-large-table-add-drop-column --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 113-large-table-add-drop-column --no-seed
```
