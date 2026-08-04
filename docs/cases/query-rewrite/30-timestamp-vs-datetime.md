# 时区与 TIMESTAMP vs DATETIME

<CaseMeta difficulty="⭐⭐" category="查询改写" versions="5.7 & 8.0" :tags="['TIMESTAMP', 'DATETIME', '时区', 'time_zone', '数据类型']" />

## 时区陷阱：跨境订单对不上数
跨境 SaaS 业务的订单表用 `TIMESTAMP` 存 `created_at`，数据录入时统一用 UTC。国内运营后台部署在东八区（+08:00），跑日报"统计 2026-07-01 当天订单数"时，发现和海外团队对不上——同一批订单，国内统计比 UTC 统计少了好几百单，高峰时段订单"消失"或"跑到次日"了。

```sql
-- 报表 SQL，看似没问题
SELECT COUNT(*) FROM t_order
WHERE created_at >= '2026-07-01 00:00:00'
  AND created_at <  '2026-07-02 00:00:00';
```

问题出在 `TIMESTAMP` 类型的时区转换机制。`TIMESTAMP` 内部以 UTC 秒数存储，**读取时按当前会话时区（`session time_zone`）自动转换显示**。国内连接的会话时区是 +08:00，于是 UTC 16:00~24:00 的订单被读成次日 00:00~08:00，按 `2026-07-01` 过滤时整体错位 8 小时，日报数据对不齐。

::: warning 真实场景
任何跨时区业务（跨境电商、全球 SaaS、多区域报表）都可能踩到这个坑。`TIMESTAMP` 的时区转换是**隐式**的——SQL 文本相同，不同会话时区的连接读出来的值不同，且不报错，问题极难察觉。业务时间字段（订单、活动、合同）应优先用 `DATETIME`。
:::

## 问题分析

### bad.sql

```sql
-- 同一行 created_at 在不同会话时区下读出不同值
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00)' AS session_tz, id, created_at FROM t_time_bad ORDER BY id LIMIT 3;

SET SESSION time_zone = '+08:00';
SELECT '+08:00' AS session_tz, id, created_at FROM t_time_bad ORDER BY id LIMIT 3;
```

### 查询结果对比

`created_at` 是 `TIMESTAMP`，造数据时以 UTC 写入 `'2026-07-01 08:00:00'`。切换会话时区读取：

| session_tz | id | created_at | 与 UTC 偏差 |
|------------|----|------------|-------------|
| `+00:00` (UTC) | 1 | `2026-07-01 08:00:00` | 0 |
| `+08:00` (东八区) | 1 | `2026-07-01 16:00:00` | **+8 小时** |
| `America/New_York` (夏令时 UTC-4) | 1 | `2026-07-01 04:00:00` | **-4 小时** |

**同一行数据，内部存储不变，但会话时区一变，`created_at` 读出值就跟着变。** 东八区比 UTC 整整偏移 8 小时。

### 报表 bug 复现

数据分三批以 UTC 录入：批A 800 行（`2026-07-01 08:00:00`）、批B 100 行（`2026-07-01 20:00:00`）、批C 100 行（`2026-07-02 08:00:00`）。

```sql
-- UTC 会话统计 7-1 当天
SET SESSION time_zone = '+00:00';
SELECT COUNT(*) AS cnt_0701_utc
FROM t_time_bad
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';

-- +08:00 会话统计 7-1 当天
SET SESSION time_zone = '+08:00';
SELECT COUNT(*) AS cnt_0701_plus8
FROM t_time_bad
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
```

| 会话时区 | cnt_0701 | 含义 |
|----------|----------|------|
| `+00:00` | **900** | 批A 800 + 批B 100（正确归属） |
| `+08:00` | **800** | 仅批A，**批B 被推到 7-2，少了 100 行** |

**报表 bug 直接可见**：同一批数据，UTC 会话统计 7-1 = 900，+08:00 会话统计 7-1 = 800，整整少了 100 行。原因藏在批B 的跨日归属上：

| 批次 | UTC 时刻 | UTC 归属日 | `+08:00` 显示值 | +08:00 归属日 | 是否错位 |
|------|----------|-----------|-----------------|---------------|----------|
| 批A | `2026-07-01 08:00:00` | 7-1 | `2026-07-01 16:00:00` | 7-1 | 未错位 |
| 批B | `2026-07-01 20:00:00` | 7-1 | `2026-07-02 04:00:00` | **7-2** | **错位 +1 天** |
| 批C | `2026-07-02 08:00:00` | 7-2 | `2026-07-02 16:00:00` | 7-2 | 未错位 |

批B 的 `20:00 UTC` 在 +08:00 会话下被读成次日 `04:00`，归属日错误。按 UTC 录入、按 +08:00 切日统计时，UTC 16:00~24:00 的订单会被整体推到次日，**日报数据错位 8 小时**，晚间高峰订单归属错误最严重。

### 为什么会错位

`TIMESTAMP` 的存储与读取机制：

```
MySQL TIMESTAMP 机制:
1. 写入: 把字面量按"当前会话时区"解释成 UTC 秒数存储      (字面量 -> UTC)
2. 读取: 把 UTC 秒数按"当前会话时区"转换成字面量显示        (UTC -> 字面量)
3. 关键: 读写都依赖"当前会话时区"，会话时区不同 -> 读出值不同
```

```
本案例写入 '2026-07-01 08:00:00' (会话时区 +00:00):
  -> 解释为 UTC 08:00，内部存 UTC 时间戳 2026-07-01 08:00:00 UTC

读取 (会话时区 +08:00):
  -> UTC 08:00 转成 +08:00 显示 = 2026-07-01 16:00:00  (偏移 +8 小时)

读取 (会话时区 America/New_York, 夏令时 -4):
  -> UTC 08:00 转成 -4 显示 = 2026-07-01 04:00:00      (偏移 -4 小时)
```

问题根源：**TIMESTAMP 把"绝对时刻"存成 UTC，但显示时按会话时区换算**。会话时区是连接级配置，不同服务、不同部署区域默认值不同，导致同一行数据读出来值不一致，业务时间归属漂移。

::: tip 核心认知
`TIMESTAMP` 存的是"绝对时刻"（UTC 秒数），适合日志类"事件发生时刻"；`DATETIME` 存的是"业务语义时间"（字面量原样），适合订单类"业务约定时间"。跨时区业务时间用 `DATETIME`，需要展示目标时区时用 `CONVERT_TZ()` 显式转换。
:::

## 优化方案

### good.sql

```sql
-- DATETIME 存业务时间，不受会话时区影响
SET SESSION time_zone = '+08:00';
SELECT id, created_at FROM t_time_good ORDER BY id LIMIT 3;
-- created_at 始终是 2026-07-01 08:00:00，与会话时区无关

-- 需要时区展示时，用 CONVERT_TZ() 显式转换
SELECT id,
       created_at AS created_utc,
       CONVERT_TZ(created_at, '+00:00', '+08:00') AS created_shanghai
FROM t_time_good ORDER BY id LIMIT 3;
```

### 原理

`DATETIME` 原样存储 `YYYY-MM-DD HH:MM:SS`，**不随 session time_zone 转换**：

```
MySQL DATETIME 机制:
1. 写入: 字面量原样存储，不做时区转换
2. 读取: 原样返回存储值，不做时区转换
3. 关键: 读写都不依赖会话时区 -> 同一行读出值始终一致
```

```
本案例写入 '2026-07-01 08:00:00':
  -> 原样存 2026-07-01 08:00:00 (内部不存 UTC 秒数)

读取 (任意会话时区):
  -> 原样返回 2026-07-01 08:00:00  (永远不变)
```

需要按目标时区展示时，用 `CONVERT_TZ(created_at, '+00:00', '+08:00')` 在查询层显式转换。**转换逻辑写在 SQL 里，可追溯、可测试**，存储值不变，不依赖会话时区配置。

### 查询结果对比（DATETIME，任意会话时区一致）

| session_tz | id | created_at | 与 UTC 偏差 |
|------------|----|------------|-------------|
| `+00:00` (UTC) | 1 | `2026-07-01 08:00:00` | 0 |
| `+08:00` (东八区) | 1 | `2026-07-01 08:00:00` | **0** |
| `America/New_York` | 1 | `2026-07-01 08:00:00` | **0** |

任意会话时区下，统计 7-1 当天订单数都稳定为 900，无错位：

| 会话时区 | cnt_0701 | 说明 |
|----------|----------|------|
| `+00:00` | 900 | 稳定 |
| `+08:00` | 900 | **与 UTC 一致，无错位** |

### 选型决策表

| 业务场景 | 推荐类型 | 理由 |
|----------|----------|------|
| 订单创建/支付时间 | **DATETIME** | 业务语义时间，跨时区报表需稳定，避免归属日漂移 |
| 活动/促销开始结束时间 | **DATETIME** | 业务约定时刻，按固定时区录入，原样存取 |
| 合同到期日、长期会员 | **DATETIME** | 可能跨越 2038，TIMESTAMP 无法存储远期日期 |
| 用户生日、历史日期 | **DATETIME** | 早于 1970 的日期 TIMESTAMP 不支持 |
| 服务器访问日志、操作审计 | **TIMESTAMP** | 事件绝对时刻，自动 UTC 存储省空间，适合排序/清理 |
| 消息推送时间戳、心跳上报 | **TIMESTAMP** | 绝对时刻，4 字节省空间，无需跨时区对齐业务语义 |
| 跨时区 SaaS 业务时间 | **DATETIME + CONVERT_TZ** | 存业务时间稳定，查询时显式转目标时区展示 |

### 对比：TIMESTAMP vs DATETIME 全维度

| 维度 | TIMESTAMP | DATETIME |
|------|-----------|----------|
| 存储格式 | UTC 秒数（4 字节整数） | 原样 `YYYY-MM-DD HH:MM:SS`（5~8 字节） |
| 存储空间 | 4 字节（无小数秒） | 5 字节（8.0）/ 8 字节（5.7），无小数秒 |
| 时间范围 | `1970-01-01` ~ `2038-01-19 03:14:07` UTC | `1000-01-01` ~ `9999-12-31 23:59:59` |
| 时区行为 | 读写按 session time_zone **自动转换** | **不转换**，原样存取 |
| 同一行不同时区读出值 | **不同**（随会话时区偏移） | **相同**（始终一致） |
| 2038 问题 | **有**（2038 后无法写入） | 无 |
| 跨时区业务 | 易错位，需统一会话时区 | 稳定，转换显式可控 |
| 自动初始化/更新 | 支持 `DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE` | 5.7.2+ 同样支持 |

<ExplainCompare
  :bad="{ type: 'TIMESTAMP', key: '读出值随会话时区变化', rows: '同', Extra: '+08:00 读出 16:00 (偏移 8h)' }"
  :good="{ type: 'DATETIME', key: '读出值与会话时区无关', rows: '同', Extra: '任意时区读出 08:00 (不变)' }"
  improvement="DATETIME 消除会话时区隐式转换，跨时区报表数据不再错位 8 小时；无 2038 限制，适合长期业务表"
/>

## 避坑指南

::: warning 注意事项

1. **时区配置要统一**。`TIMESTAMP` 的行为依赖 `session time_zone`，不同连接默认值可能不同。要么全局统一（`SET GLOBAL time_zone='+00:00'`），要么改用 `DATETIME` 规避隐式转换。JDBC 连接建议显式指定 `serverTimezone` 参数，避免驱动用本地时区解释。

2. **警惕 2038 年问题**。`TIMESTAMP` 用 4 字节存 UTC 秒数，上限 `2038-01-19 03:14:07 UTC`。合同到期、长期会员、生日等远期/历史日期若用 `TIMESTAMP`，2038 年后将无法写入。长期业务表一律用 `DATETIME`。

3. **TIMESTAMP 迁移到 DATETIME 注意时区**。`ALTER TABLE ... MODIFY created_at DATETIME` 时，MySQL 会把 `TIMESTAMP` 的 UTC 值按当前会话时区转成字面量再存为 `DATETIME`。迁移前务必统一会话时区（如 `SET SESSION time_zone='+00:00'`），否则会引入二次偏移。建议先在测试库验证迁移后的值是否符合预期。

4. **CONVERT_TZ 用命名时区需加载时区表**。`CONVERT_TZ(dt, 'UTC', 'Asia/Shanghai')` 需要 `mysql.time_zone_name` 等时区表已加载，否则返回 `NULL`。加载命令：`mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql`。用偏移量（`'+00:00'`）不需要时区表，但不能处理夏令时。

5. **CONVERT_TZ 作用于索引列会使索引失效**。`WHERE CONVERT_TZ(created_at, ...) >= '...'` 是函数作用于索引列，优化器无法走索引范围扫描，退化为全表扫描。大表上建议在应用层转换，或预存一个目标时区的派生列并建索引。

6. **JDBC/驱动时区参数**。MySQL Connector/J 的 `serverTimezone` 参数决定驱动如何解释 `TIMESTAMP`。如果库存 UTC、应用按东八区展示，配置 `serverTimezone=UTC` 并在应用层转换，避免驱动隐式偏移。`useLegacyDatetimeCode=false`（8.0 驱动默认）使用新时区处理逻辑，推荐开启。

7. **同一张表不要混用**。一张业务表里同时有 `TIMESTAMP`（如 `updated_at`）和 `DATETIME`（如 `created_at`）会让时区行为混乱——有的列随时区变、有的不变。统一用 `DATETIME` 存业务时间，`TIMESTAMP` 仅用于纯日志列。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| TIMESTAMP 时区转换 | 按 session time_zone 双向转换 | 一致 |
| DATETIME 时区行为 | 不转换，原样存取 | 一致 |
| DATETIME 存储空间 | 8 字节（无小数秒） | **5 字节**（紧凑存储） |
| TIMESTAMP 存储空间 | 4 字节 | 4 字节 |
| 命名时区支持 | 需 `mysql_tzinfo_to_sql` 加载 | 一致 |
| `DEFAULT CURRENT_TIMESTAMP` for DATETIME | 5.7.2+ 支持 | 支持 |
| 超范围 TIMESTAMP 写入 | 严格模式报错 / 非严格置 0 警告 | 一致，警告更明确 |

::: tip 8.0 改进
8.0 对 DATETIME 做了紧凑存储优化：无小数秒时从 5.7 的 8 字节降到 5 字节，存储空间与 TIMESTAMP（4 字节）差距缩小到 1 字节。对大表的时间列，8.0 的 DATETIME 更节省空间，选型时不必为省 1 字节而忍受 TIMESTAMP 的时区隐式转换和 2038 限制。两版的时区转换机制完全一致，迁移无行为差异。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 30-timestamp-vs-datetime

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 30-timestamp-vs-datetime --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 30-timestamp-vs-datetime --no-seed
```

::: tip 复现要点
本案例重点观察 `bad.sql` / `good.sql` 中切换 `SET SESSION time_zone` 后 `created_at` 读出值的变化。`t_time_bad`（TIMESTAMP）的值随时区偏移，`t_time_good`（DATETIME）的值始终不变。命名时区（`America/New_York`）需先加载时区表，否则会话时区设置会失败，可用偏移量 `'-04:00'` 替代验证。
:::
