-- good.sql: 用 DATETIME 类型 + 闭开区间范围查询
-- 正解思路:
--   1. 时间字段用原生 DATETIME 类型存储，而非 VARCHAR 字符串
--   2. 范围查询用闭开区间 [start, end): created_at >= start AND created_at < end
--   3. 不在索引列上包裹任何函数，索引可正常走 range 范围扫描
-- =====================================================================

-- =====================================================================
-- 正解: DATETIME 类型 + 闭开区间范围查询（半开半闭，避免边界陷阱）
-- SELECT * FROM t_time_good
-- WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
-- 优势:
--   - created_at 是 DATETIME，比较是真正的时间比较，不依赖字符串格式补零
--   - 闭开区间 [2026-07-01 00:00:00, 2026-07-02 00:00:00) 精确覆盖"7-1 当天"，
--     既不漏掉 23:59:59，也不会把 7-2 00:00:00 算进来，无边界歧义
--   - 列保持原始形态(不包裹函数)，idx_created 走 range 范围扫描
SELECT '正解: DATETIME+闭开区间' AS scenario,
       id, user_id, amount, created_at
FROM   t_time_good
WHERE  created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00'
ORDER BY created_at
LIMIT  10;

-- 统计 7-1 当天行数（含固定数据 + 随机落在当天的数据）
SELECT '正解: 统计7-1当天行数' AS scenario,
       COUNT(*) AS cnt_0701
FROM   t_time_good
WHERE  created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';
-- 预期至少 3 行（固定数据），加上随机数据中落在当天的行。

-- EXPLAIN: 验证走索引范围扫描
EXPLAIN
SELECT id FROM t_time_good
WHERE created_at >= '2026-07-01 00:00:00' AND created_at < '2026-07-02 00:00:00';

-- =====================================================================
-- 为什么用闭开区间 [start, end) 而不是闭区间 [start, end]?
--   - 闭开区间天然按"天的起点"切分，无需知道一天的结束时刻(23:59:59)，
--     也不会漏掉 23:59:59.999999(若 DATETIME 有小数秒)
--   - end = 次日 00:00:00 是下一天的起点，[今天起点, 明天起点) 即"今天"，语义清晰
--   - 连续多天查询也只需拼接区间，不会重叠也不会遗漏:
--       7-1: [07-01 00:00, 07-02 00:00)
--       7-2: [07-02 00:00, 07-03 00:00)
--     7-2 00:00:00 严格属于 7-2，不与 7-1 重叠。
-- =====================================================================

-- =====================================================================
-- DATETIME 类型的正确性验证: 时间函数与排序均按时间语义工作
-- =====================================================================

-- 可用时间函数做日期运算(VARCHAR 做不到或需隐式转换)
SELECT '时间函数: DATEDIFF/DATE_ADD' AS scenario,
       id,
       created_at,
       DATE(created_at)            AS created_date,
       DATE_ADD(created_at, INTERVAL 1 DAY) AS next_day,
       DATEDIFF(NOW(), created_at) AS days_ago
FROM   t_time_good
ORDER BY created_at DESC
LIMIT  3;

-- 排序按时间序(而非字符串字典序)，格式不影响排序正确性
SELECT '时间排序: ORDER BY created_at' AS scenario,
       id, created_at
FROM   t_time_good
ORDER BY created_at DESC
LIMIT  3;
