# 查询结果参考 - good.sql（DATETIME 在不同时区下读出值一致）

> 本案例重点不在 EXPLAIN 执行计划，而在 **DATETIME 不受 session time_zone 影响**，
> 同一行在任何会话时区下读出值都一致；需要时区展示时用 `CONVERT_TZ()` 显式转换。

## 1. 同一行 created_at 在不同会话时区下的显示值（t_time_good, DATETIME）

```sql
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00)' AS session_tz, id, created_at FROM t_time_good ORDER BY id LIMIT 3;

SET SESSION time_zone = '+08:00';
SELECT '+08:00' AS session_tz, id, created_at FROM t_time_good ORDER BY id LIMIT 3;

SET SESSION time_zone = 'America/New_York';
SELECT 'America/New_York' AS session_tz, id, created_at FROM t_time_good ORDER BY id LIMIT 3;
```

| session_tz | id | created_at | 与 UTC 偏差 |
|------------|----|------------|-------------|
| `+00:00` (UTC) | 1 | `2026-07-01 08:00:00` | 0 |
| `+08:00` (东八区) | 1 | `2026-07-01 08:00:00` | **0** |
| `America/New_York` (夏令时 UTC-4) | 1 | `2026-07-01 08:00:00` | **0** |

**关键现象**：无论会话时区如何变化，DATETIME 列读出值始终一致。业务时间稳定可解释，跨时区报表对齐。

## 2. 报表统计："统计 2026-07-01 当天订单数"（DATETIME，任意会话时区结果一致）

数据分三批以 UTC 录入（批A 800 行 7-1 08:00、批B 100 行 7-1 20:00、批C 100 行 7-2 08:00），DATETIME 原样存储。

```sql
SET SESSION time_zone = '+08:00';
SELECT COUNT(*) AS cnt_0701 FROM t_time_good
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';

SET SESSION time_zone = '+00:00';
SELECT COUNT(*) AS cnt_0701 FROM t_time_good
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
```

| 会话时区 | 过滤区间（字面量） | cnt_0701 | 说明 |
|----------|--------------------|----------|------|
| `+00:00` | `2026-07-01 00:00 ~ 2026-07-02 00:00` | **900** | 批A 800 + 批B 100 |
| `+08:00` | `2026-07-01 00:00 ~ 2026-07-02 00:00` | **900** | **与 UTC 一致，无错位** |

与 bad 方案对比：bad 表（TIMESTAMP）在 +08:00 会话下统计 7-1 只有 800（批B 被推到 7-2）；good 表（DATETIME）在任意会话时区下都是 900，归属日由存储值唯一确定，不随会话时区漂移。

## 3. 需要时区展示时用 CONVERT_TZ() 显式转换

```sql
SET SESSION time_zone = '+00:00';
SELECT id,
       created_at AS created_utc,
       CONVERT_TZ(created_at, '+00:00', '+08:00') AS created_shanghai,
       CONVERT_TZ(created_at, '+00:00', 'America/New_York') AS created_newyork
FROM t_time_good ORDER BY id LIMIT 3;
```

| id | created_utc | created_shanghai | created_newyork |
|----|-------------|------------------|-----------------|
| 1 | `2026-07-01 08:00:00` | `2026-07-01 16:00:00` | `2026-07-01 04:00:00` |
| 2 | `2026-07-01 08:00:00` | `2026-07-01 16:00:00` | `2026-07-01 04:00:00` |
| 3 | `2026-07-01 08:00:00` | `2026-07-01 16:00:00` | `2026-07-01 04:00:00` |

转换发生在**查询层**，存储的 `created_at` 始终是 `08:00:00` 不变。转换逻辑写在 SQL 里，行为可追溯、可测试，不依赖会话时区配置。

```sql
-- 报表按"东八区当天"统计，用 CONVERT_TZ 转换后再过滤
SELECT COUNT(*) AS cnt_0701_shanghai
FROM t_time_good
WHERE CONVERT_TZ(created_at, '+00:00', '+08:00') >= '2026-07-01 00:00:00'
  AND CONVERT_TZ(created_at, '+00:00', '+08:00') <  '2026-07-02 00:00:00';
-- 预期 cnt_0701_shanghai = 800（仅批A: 08:00 UTC -> 16:00 +08 仍在 7-1）
--   批B 20:00 UTC -> 7-2 04:00 +08，属于东八区的 7-2，不计入 7-1（显式且正确）
```

| 统计口径 | SQL 写法 | cnt_0701 | 含义 |
|----------|----------|----------|------|
| UTC 当天 | `WHERE created_at >= '2026-07-01' AND < '2026-07-02'` | 900 | 批A + 批B |
| 东八区当天 | `WHERE CONVERT_TZ(created_at,'+00:00','+08:00') >= '2026-07-01' ...` | 800 | 仅批A |

两种口径都是 SQL 显式选择的，转换逻辑可追溯、可测试，不随会话时区漂移。这正是 DATETIME + CONVERT_TZ 相比 TIMESTAMP 隐式转换的核心优势。

::: warning CONVERT_TZ 使用注意
- 用偏移量（如 `'+00:00'`、`'+08:00'`）不需要时区表，随时可用。
- 用命名时区（如 `'America/New_York'`、`'Asia/Shanghai'`）需要先加载时区表：
  `mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql`，否则 `CONVERT_TZ` 返回 `NULL`。
- 命名时区能正确处理夏令时，偏移量不能（夏令时期间偏移会变）。跨夏令时业务优先用命名时区。
- `CONVERT_TZ` 作用于索引列会使索引失效（函数作用于索引列），大表上建议在应用层转换或预存转换后的列。
:::

## 4. EXPLAIN 执行计划（无差异，仅供参考）

```
+----+-------------+-------------+------------+-------+---------------+-------------+---------+------+------+----------+-----------------------+
| id | select_type | table       | partitions | type  | possible_keys | key         | key_len | ref  | rows | filtered | Extra                 |
+----+-------------+-------------+------------+-------+---------------+-------------+---------+------+------+----------+-----------------------+
|  1 | SIMPLE      | t_time_good | NULL       | range | idx_created   | idx_created | 5       | NULL |  900 |   100.00 | Using index condition |
+----+-------------+-------------+------------+-------+---------------+-------------+---------+------+------+----------+-----------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `range` | 索引范围扫描 |
| key | `idx_created` | 走 created_at 索引 |
| key_len | `5` | DATETIME（8.0 默认 5 字节，无小数秒） |
| rows | ~900 | 预估扫描 900 行 |
| Extra | `Using index condition` | 索引条件下推 |

> 注：`CONVERT_TZ(created_at, ...)` 作用于索引列时索引失效，会退化为全表扫描。本节 EXPLAIN 是不带 CONVERT_TZ 的纯范围查询，仅说明 DATETIME 范围扫描与 TIMESTAMP 执行计划无差异。

## 量化对比：TIMESTAMP vs DATETIME 全维度

| 维度 | TIMESTAMP | DATETIME |
|------|-----------|----------|
| 存储格式 | UTC 秒数（4 字节整数） | 原样 `YYYY-MM-DD HH:MM:SS`（5~8 字节） |
| 存储空间 | 4 字节（无小数秒） | 5 字节（8.0 无小数秒）/ 8 字节（5.7） |
| 时间范围 | `1970-01-01 00:00:01` ~ `2038-01-19 03:14:07` UTC | `1000-01-01 00:00:00` ~ `9999-12-31 23:59:59` |
| 时区行为 | 读写按 session time_zone **自动转换** | **不转换**，原样存取 |
| 同一行不同时区读出值 | **不同**（随会话时区偏移） | **相同**（始终一致） |
| 2038 问题 | **有**（2038 后无法写入） | 无 |
| 跨时区业务 | 易错位，需统一会话时区 | 稳定，转换显式可控 |
| 索引 key_len | 4 | 5（8.0）/ 8（5.7） |
| 自动初始化/更新 | 支持 `DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE` | 5.7.2+ 同样支持 |
| 适用场景 | 服务器日志、操作审计、事件绝对时刻 | 订单时间、活动时间、合同到期等业务时间 |

## 选型决策表

| 业务场景 | 推荐类型 | 理由 |
|----------|----------|------|
| 订单创建/支付时间 | **DATETIME** | 业务语义时间，跨时区报表需稳定，避免归属日漂移 |
| 活动/促销开始结束时间 | **DATETIME** | 业务约定时刻，按固定时区录入，原样存取 |
| 合同到期日、长期会员 | **DATETIME** | 可能跨越 2038，TIMESTAMP 无法存储远期日期 |
| 用户生日、历史日期 | **DATETIME** | 早于 1970 的日期 TIMESTAMP 不支持 |
| 服务器访问日志、操作审计 | **TIMESTAMP** | 事件发生的绝对时刻，自动 UTC 存储省空间，适合按时间排序/清理 |
| 消息推送时间戳、心跳上报 | **TIMESTAMP** | 绝对时刻，4 字节省空间，无需跨时区对齐业务语义 |
| 跨时区 SaaS 业务时间 | **DATETIME + CONVERT_TZ** | 存业务时间稳定，查询时显式转目标时区展示 |

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| TIMESTAMP 时区转换 | 按 session time_zone 双向转换 | 一致 |
| DATETIME 时区行为 | 不转换，原样存取 | 一致 |
| DATETIME 存储空间 | 8 字节（无小数秒） | **5 字节**（无小数秒，8.0 紧凑存储） |
| TIMESTAMP 存储空间 | 4 字节 | 4 字节 |
| 命名时区支持 | 需 `mysql_tzinfo_to_sql` 加载 | 一致 |
| `DEFAULT CURRENT_TIMESTAMP` for DATETIME | 5.7.2+ 支持 | 支持 |
| 超范围 TIMESTAMP 写入 | 严格模式报错 / 非严格置 0 警告 | 一致，警告更明确 |

::: tip 8.0 改进
8.0 对 DATETIME 做了紧凑存储优化：无小数秒时从 5.7 的 8 字节降到 5 字节，存储空间与 TIMESTAMP（4 字节）差距缩小。对大表的时间列，8.0 的 DATETIME 更节省空间，选型时不必为省 1 字节而忍受 TIMESTAMP 的时区隐式转换和 2038 限制。
:::
