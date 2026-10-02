-- good.sql: 用 DATETIME 存业务时间，不受 session time_zone 影响；需要时区转换时显式 CONVERT_TZ
-- DATETIME 原样存储 YYYY-MM-DD HH:MM:SS，读出值与会话时区无关，
-- 跨时区报表对同一行永远读到相同的 created_at，业务时间稳定可解释。

-- =====================================================================
-- 1) 同一行 created_at 在不同会话时区下的显示值对比（DATETIME）
--    造数据时以 UTC 字面量 '2026-07-01 08:00:00' 写入，DATETIME 原样存储。
-- =====================================================================

-- 1.1 会话时区 = UTC(+00:00): 读出 08:00:00
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00)' AS session_tz,
       id, created_at
FROM   t_time_good
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 08:00:00

-- 1.2 会话时区 = 东八区(+08:00): 读出值不变! DATETIME 不随时区转换
SET SESSION time_zone = '+08:00';
SELECT '+08:00' AS session_tz,
       id, created_at
FROM   t_time_good
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 08:00:00  (与 UTC 完全一致)

-- 1.3 会话时区 = 美东(America/New_York): 读出值仍不变
SET SESSION time_zone = 'America/New_York';
SELECT 'America/New_York' AS session_tz,
       id, created_at
FROM   t_time_good
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 08:00:00  (与 UTC 完全一致)

-- =====================================================================
-- 2) 报表统计: "统计 2026-07-01 当天的订单数"（DATETIME，任意会话时区结果一致）
--    业务约定 created_at 存的就是业务发生时间（按某个固定时区录入），
--    用字面量过滤在任何会话时区下结果都稳定。
-- =====================================================================

-- 任意会话时区下，统计 7-1 当天订单数都是 900（DATETIME 不受时区影响）
SET SESSION time_zone = '+08:00';
SELECT '+08:00 会话, DATETIME 过滤 2026-07-01' AS scenario,
       COUNT(*) AS cnt_0701
FROM   t_time_good
WHERE  created_at >= '2026-07-01 00:00:00'
  AND  created_at <  '2026-07-02 00:00:00';
-- 预期 cnt_0701 = 900

SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00) 会话, DATETIME 过滤 2026-07-01' AS scenario,
       COUNT(*) AS cnt_0701
FROM   t_time_good
WHERE  created_at >= '2026-07-01 00:00:00'
  AND  created_at <  '2026-07-02 00:00:00';
-- 预期 cnt_0701 = 900  (两时区结果一致，无错位)

-- =====================================================================
-- 3) 真正需要时区展示时，用 CONVERT_TZ() 显式转换，而不是依赖会话时区隐式转换
--    CONVERT_TZ(dt, from_tz, to_tz) 在查询层完成转换，
--    存储值不变，转换逻辑写在 SQL 里，行为可追溯、可测试。
--    (from_tz/to_tz 用命名时区如 'UTC'/'Asia/Shanghai' 需加载时区表)
-- =====================================================================

-- 把 DATETIME 存的业务时间(UTC)显式转成东八区展示
SET SESSION time_zone = '+00:00';
SELECT id,
       created_at AS created_utc,
       CONVERT_TZ(created_at, '+00:00', '+08:00') AS created_shanghai,
       CONVERT_TZ(created_at, '+00:00', 'America/New_York') AS created_newyork
FROM   t_time_good
ORDER BY id
LIMIT  3;
-- 预期:
--   created_utc       = 2026-07-01 08:00:00
--   created_shanghai  = 2026-07-01 16:00:00  (显式 +8 转换)
--   created_newyork   = 2026-07-01 04:00:00  (显式 -4 转换, 夏令时)
--   转换发生在查询层，存储的 created_at 始终是 08:00:00 不变。

-- 报表按"东八区当天"统计，用 CONVERT_TZ 把存储的 UTC 业务时间转 +8 后再过滤:
SELECT 'CONVERT_TZ 转 +08 后统计 7-1' AS scenario,
       COUNT(*) AS cnt_0701_shanghai
FROM   t_time_good
WHERE  CONVERT_TZ(created_at, '+00:00', '+08:00') >= '2026-07-01 00:00:00'
  AND  CONVERT_TZ(created_at, '+00:00', '+08:00') <  '2026-07-02 00:00:00';
-- 预期 cnt_0701_shanghai = 800  (仅批A: 08:00 UTC -> 16:00 +08, 仍在 7-1)
--   批B 20:00 UTC -> 7-2 04:00 +08, 属于东八区的 7-2, 不计入 7-1 (显式且正确)
-- 对比: 直接按存储的 UTC 业务时间统计 7-1 = 批A+批B = 900 (上面第 2 节)
--   -> "按哪天统计"是 SQL 显式选择的(UTC 天 vs 东八区天)，不随会话时区漂移。
-- 转换逻辑写在 SQL 里，不依赖会话时区配置，结果可复现。

-- =====================================================================
-- 4) 选型决策（注释说明）
--    - TIMESTAMP: 存"自 1970 UTC 起的秒数"，读写自动按会话时区转换，
--      适合存"事件发生的绝对时刻"，如服务器日志、操作审计、消息时间戳。
--      占 4 字节，但受 2038 限制，范围 1970~2038。
--    - DATETIME: 原样存 'YYYY-MM-DD HH:MM:SS'，不随时区改变，
--      适合存"业务语义时间"，如订单创建时间、活动开始时间、合同到期日。
--      占 5~8 字节(8.0 默认 5 字节,小数秒另算)，范围 1000~9999，无 2038 问题。
--    - 跨时区业务首选 DATETIME 存业务时间 + 查询时 CONVERT_TZ 显式转换，
--      避免会话时区隐式转换带来的"同一行读出不同值"的不可预测行为。
-- =====================================================================

-- 复位会话时区
SET SESSION time_zone = '+00:00';
