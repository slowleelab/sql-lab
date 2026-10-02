-- bad.sql: TIMESTAMP 在不同 session time_zone 下读出不同值，导致报表错位 8 小时
-- TIMESTAMP 内部以 UTC 秒数存储，读取时按当前会话时区转换显示。
-- 同一行数据，会话时区一变，created_at 就跟着变 -> 跨时区报表对不齐。

-- =====================================================================
-- 1) 同一行 created_at 在不同会话时区下的显示值对比
--    造数据时以 UTC 写入 '2026-07-01 08:00:00'，内部存的就是 UTC 08:00。
-- =====================================================================

-- 1.1 会话时区 = UTC(+00:00): 读出 08:00:00
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00)' AS session_tz,
       id, created_at
FROM   t_time_bad
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 08:00:00

-- 1.2 会话时区 = 东八区(+08:00): 读出 16:00:00，整整偏移 8 小时!
SET SESSION time_zone = '+08:00';
SELECT '+08:00' AS session_tz,
       id, created_at
FROM   t_time_bad
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 16:00:00  (与 UTC 相差 8 小时)

-- 1.3 会话时区 = 美东(America/New_York, UTC-4 夏令时): 读出 04:00:00
--     需要时区表已加载: mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql
SET SESSION time_zone = 'America/New_York';
SELECT 'America/New_York' AS session_tz,
       id, created_at
FROM   t_time_bad
ORDER BY id
LIMIT  3;
-- 预期 created_at = 2026-07-01 04:00:00  (与 UTC 相差 -4 小时, 夏令时)

-- =====================================================================
-- 2) 报表 bug 复现: "统计 2026-07-01 当天的订单数"
--    数据分三批以 UTC 录入:
--      批A 800 行: 2026-07-01 08:00:00 UTC
--      批B 100 行: 2026-07-01 20:00:00 UTC  (晚间订单)
--      批C 100 行: 2026-07-02 08:00:00 UTC
--    UTC 会话统计 7-1 当天 = 批A + 批B = 900 行。
--    切到 +08:00 会话后，批B 的 20:00 UTC 被读成次日 04:00(+08)，归到 7-2，
--    统计 7-1 当天只剩 批A = 800 行，整整少了 100 行(批B)。
-- =====================================================================

-- 2.1 UTC(+00:00) 会话: 批A、批B 都落在 7-1，统计 7-1 = 900 行
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00) 会话, 用 2026-07-01 过滤' AS scenario,
       COUNT(*) AS cnt_0701_utc
FROM   t_time_bad
WHERE  created_at >= '2026-07-01 00:00:00'
  AND  created_at <  '2026-07-02 00:00:00';
-- 预期 cnt_0701_utc = 900  (批A 800 + 批B 100)

-- 2.2 +08:00 会话: 批B 的 20:00 UTC -> 显示 7-2 04:00，被切到次日
SET SESSION time_zone = '+08:00';
SELECT '+08:00 会话, 用 2026-07-01 过滤' AS scenario,
       COUNT(*) AS cnt_0701_plus8
FROM   t_time_bad
WHERE  created_at >= '2026-07-01 00:00:00'
  AND  created_at <  '2026-07-02 00:00:00';
-- 预期 cnt_0701_plus8 = 800  <-- 报表 bug! 比 UTC 少了 100 行(批B)
-- 原因: 批B 的 created_at 在 +08:00 会话下从 2026-07-01 20:00:00 被读成
--       2026-07-02 04:00:00，落在 [7-02 00:00, 7-03 00:00) 区间，
--       不再满足 [7-01 00:00, 7-02 00:00) 过滤 -> 被错误归到次日。
--       日报数据整体错位 8 小时，晚间订单(UTC 16:00~24:00)归属日错误。

-- 2.3 验证批B确实跑到 7-2 去了: +08:00 会话统计 7-2 会多出批B
SET SESSION time_zone = '+08:00';
SELECT '+08:00 会话, 用 2026-07-02 过滤' AS scenario,
       COUNT(*) AS cnt_0702_plus8
FROM   t_time_bad
WHERE  created_at >= '2026-07-02 00:00:00'
  AND  created_at <  '2026-07-03 00:00:00';
-- 预期 cnt_0702_plus8 = 200  (批B 100 + 批C 100)
-- 对比 UTC 会话统计 7-2 只有 批C = 100 行 -> +08:00 多算了批B 的 100 行。
SET SESSION time_zone = '+00:00';
SELECT 'UTC(+00:00) 会话, 用 2026-07-02 过滤' AS scenario,
       COUNT(*) AS cnt_0702_utc
FROM   t_time_bad
WHERE  created_at >= '2026-07-02 00:00:00'
  AND  created_at <  '2026-07-03 00:00:00';
-- 预期 cnt_0702_utc = 100  (仅批C)

-- =====================================================================
-- 3) TIMESTAMP 的 2038 年问题（Y2038）
--    TIMESTAMP 内部用 4 字节有符号整数存"自 1970-01-01 00:00:00 UTC 起的秒数"，
--    上限 = 2^31 - 1 = 2147483647 秒 = 2038-01-19 03:14:07 UTC。
--    超过该时刻的时间无法用 TIMESTAMP 存储，写入会报错或被截断为 0。
-- =====================================================================
-- SELECT FROM_UNIXTIME(2147483647);  -- 2038-01-19 03:14:07 (TIMESTAMP 上限, UTC)
-- SELECT FROM_UNIXTIME(2147483648);  -- 8.0: NULL / 5.7: 警告并置 0 -> 2038 问题
-- 对比 DATETIME: 范围 '1000-01-01 00:00:00' ~ '9999-12-31 23:59:59'，无 2038 限制。
-- 长期业务表（如合同到期、长期会员）不应使用 TIMESTAMP，避免 2038 后数据无法写入。

-- 复位会话时区，避免影响后续脚本
SET SESSION time_zone = '+00:00';
