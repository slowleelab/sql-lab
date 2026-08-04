# 自增主键耗尽与分布式 ID

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['AUTO_INCREMENT', 'INT 溢出', '雪花ID', '分布式ID', '主键设计']" />

## 订单表突然无法写入
某电商系统运行 3 年后，订单表突然无法写入，所有下单请求报错：

```
ERROR 1467 (HY000): Failed to read auto-increment value from storage engine
```

排查发现，订单表使用 `INT UNSIGNED` 自增主键，AUTO_INCREMENT 已达到 **4,294,967,295**（约 42.9 亿上限），再也无法分配新 ID。这不是慢查询，是**整个写入链路直接中断**。

```sql
-- 查看剩余可用 ID
SELECT AUTO_INCREMENT,
       4294967295 - AUTO_INCREMENT AS remaining_slots
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_bad';
-- 结果：remaining_slots = 0，已耗尽
```

紧急扩容 `INT -> BIGINT` 需要对亿级大表做 `ALTER TABLE`，期间锁表数小时，业务完全不可用。

::: warning 真实场景
这是真实事故。使用 `INT`（有符号，上限 21.5 亿）的表 2-3 年就可能耗尽；`INT UNSIGNED` 也只能撑 4-5 年。任何用自增整型做主键的表，如果数据增长快，都必须提前规划迁移。一旦耗尽，修复窗口极短，损失巨大。
:::

## 问题分析

### bad.sql

```sql
-- 订单表使用 INT UNSIGNED 自增主键
CREATE TABLE t_order_bad (
    id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    ...
    PRIMARY KEY (id)
) ENGINE=InnoDB AUTO_INCREMENT=4294967290;
--                               ^^^^^^^^^^^ 已接近上限

-- 继续插入 -> 报错
INSERT INTO t_order_bad (order_no, user_id, amount, status, created_at)
VALUES ('ORD_OVERFLOW', 9999, 1.00, 0, NOW());
-- ERROR 1467: Failed to read auto-increment value from storage engine
```

### 为什么危险

各整型主键的上限对比：

| 类型 | 上限 | 预计耗尽时间（1000 ID/秒） |
|------|------|--------------------------|
| `INT` (有符号) | 2,147,483,647 (21.5 亿) | ~25 天 |
| `INT UNSIGNED` | 4,294,967,295 (42.9 亿) | ~50 天 |
| `BIGINT` | 9,223,372,036,854,775,807 (9.2×10¹⁸) | ~29 万年 |

> 注意：1000 ID/秒是保守估计，高并发系统可达数万/秒。实际中 INT 通常撑 3-5 年。

耗尽后的连锁反应：

```
1. INSERT 报错 -> 所有写入中断
2. 紧急 ALTER TABLE INT -> BIGINT
   -> 亿级表锁表数小时（或用 pt-osc 工具但仍需小时级迁移）
3. 迁移期间业务不可用或降级
4. 如果是多分库分表，需逐个迁移，风险叠加
```

::: tip 核心认知
主键类型选择是架构设计的第一步，选错代价极高。新表一律用 `BIGINT`，分布式场景用雪花 ID。`INT` 只适用于明确知道数据量不会超过 20 亿的小表。
:::

## 优化方案

### good.sql

```sql
-- 使用 BIGINT + 应用层雪花 ID（Snowflake）
CREATE TABLE t_order_good (
    id  BIGINT NOT NULL COMMENT '雪花ID（应用层生成）',
    ...
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- 应用层生成 ID 后直接插入，不依赖 MySQL 自增
INSERT INTO t_order_good (id, order_no, user_id, amount, status, created_at)
VALUES (1752500000000000006, 'ORD_OVERFLOW', 9999, 1.00, 0, NOW());
-- 插入成功，永不耗尽
```

### 雪花算法原理

64 bit ID 结构：

```
| 1 bit | 41 bit 时间戳 | 10 bit 机器ID | 12 bit 序列号 |
|  符号  |  毫秒级时间    | 1024 台机器   | 每毫秒4096个  |
```

- **41 bit 时间戳**：毫秒级，可用约 69 年（从设定纪元起算）
- **10 bit 机器 ID**：支持 1024 台机器同时生成，无需协调
- **12 bit 序列号**：同一毫秒内可生成 4096 个 ID

### 对比

| | bad: INT AUTO_INCREMENT | good: BIGINT Snowflake |
|---|---|---|
| 上限 | 42.9 亿 | 9.2 × 10¹⁸ |
| 耗尽风险 | 3-5 年触发 | 69 年不触发 |
| ID 生成 | 数据库（有锁） | 应用层（无锁） |
| 分布式 | 需设不同步长 | 原生支持 1024 节点 |
| 插入性能 | 受自增锁限制 | 无锁，更高吞吐 |
| 紧急扩容 | ALTER TABLE 锁表 | 不需要 |

<ExplainCompare
  :bad="{ type: 'INSERT 失败', key: 'INT UNSIGNED', rows: '0 剩余', Extra: 'ERROR 1467: 自增耗尽，写入中断' }"
  :good="{ type: 'INSERT 成功', key: 'BIGINT Snowflake', rows: '9.2×10¹⁸ 剩余', Extra: '应用层生成，无锁，永不耗尽' }"
  improvement="从致命写入中断到永不耗尽，同时消除自增锁争用，分布式原生支持"
/>

## 避坑指南

::: warning 注意事项

1. **新表一律 BIGINT**。不要用 `INT` 做主键，即使是"小表"也可能意外膨胀。`BIGINT` 多占 4 字节存储，但换来的是永久安全。

2. **提前监控自增水位**。设置告警：当 `AUTO_INCREMENT / 上限 > 70%` 时报警，留足迁移时间。查询脚本：
   ```sql
   SELECT TABLE_NAME, AUTO_INCREMENT,
          POW(2,32)-1-AUTO_INCREMENT AS remaining
   FROM information_schema.TABLES
   WHERE AUTO_INCREMENT > POW(2,32) * 0.7;
   ```

3. **雪花 ID 的时钟回拨问题**。机器时钟回拨会导致 ID 重复。解决方案：记录上次时间戳，回拨时等待追平或抛异常拒绝生成。

4. **雪花 ID 不是严格递增**。同一毫秒内序列号递增，但跨机器的 ID 大小不保证顺序。如果强依赖严格递增，需用数据库序列或号段模式。

5. **不要用 UUID 做主键**。UUID v4 是随机的，B+ 树插入会导致大量页分裂和碎片，写入性能差。如果要用 UUID，至少用 UUID v7（时间有序）。

6. **已有 INT 表的迁移策略**。用 `pt-online-schema-change` 或 `gh-ost` 在线迁移，避免锁表。迁移前先确认外键引用、代码中 `int` 类型的强转等。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| AUTO_INCREMENT 持久化 | ❌ 重启可能回退 | ✅ 持久化到 redo log |
| 修改 AUTO_INCREMENT | 直接修改 | 需重启或特殊操作 |
| 雪花 ID 方案 | ✅ 完全支持 | ✅ 完全支持 |
| INT -> BIGINT 迁移 | 需第三方工具 | 同左（8.0 仍需在线 DDL 工具） |

::: tip 8.0 改进
MySQL 8.0 将 `AUTO_INCREMENT` 计数器持久化到 redo log 中，重启后不会丢失。5.7 重启后可能回退到 `MAX(id)`，导致已使用的 ID 被重复分配。这使得 5.7 的自增主键在重启后有数据不一致风险。
:::

## 与案例 14 的区别

| | 案例 14：自增主键跳号 | 案例 61：自增主键耗尽 |
|---|---|---|
| 问题 | 批量 INSERT 回滚导致跳号 | ID 达到类型上限无法继续 |
| 影响 | ID 不连续，长期有溢出风险 | 写入完全中断 |
| 紧急程度 | 低（可观测可预防） | 极高（业务瘫痪） |
| 方案 | 调整 `innodb_autoinc_lock_mode` | 迁移 BIGINT 或用雪花 ID |

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 61-auto-inc-exhaustion

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 61-auto-inc-exhaustion --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 61-auto-inc-exhaustion --no-seed
```
