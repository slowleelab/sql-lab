-- bad.sql: 三种时间格式反模式
-- 共同前提: created_at 用 VARCHAR(20) 存储（如 '2026-07-01 08:00:00'）
-- 表面上能查，实际上藏着正确性陷阱和性能陷阱。

-- =====================================================================
-- 反模式 1: 字符串存时间，范围比较是字符串字典序比较
-- SELECT * FROM t_time_bad
-- WHERE created_at >= '2026-07-01' AND created_at < '2026-07-02';
-- 问题:
--   - created_at 是 VARCHAR，'2026-07-01' 也是字符串，按字典序逐字符比较
--   - 当格式统一为 'YYYY-MM-DD HH:MM:SS' 时字典序恰好与时间序一致，
--     表面"能查对"，但这是一种脆弱的巧合:
--       * 若有人存了 '2026-7-1 8:0:0'（非补零格式），字典序立刻错乱
--       * 无法用时间函数做日期运算（DATEDIFF/DATE_ADD 等）
--       * 排序是字符串排序，遇到格式不统一会出错
--   - 即使能走索引，也只是"字符串索引范围扫描"，语义是字符串比较而非时间比较
SELECT '反模式1: VARCHAR范围比较' AS scenario,
       id, user_id, amount, created_at
FROM   t_time_bad
WHERE  created_at >= '2026-07-01' AND created_at < '2026-07-02'
ORDER BY created_at
LIMIT  10;
-- 风险: 依赖"格式统一且补零"的隐式约定，格式一旦不统一结果就错，且无时间运算能力。

-- =====================================================================
-- 反模式 2: DATE_FORMAT 函数包裹字段致索引失效
-- SELECT * FROM t_time_bad
-- WHERE DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01';
-- 问题:
--   - 对 created_at 列套用 DATE_FORMAT() 函数，破坏索引有序性
--   - 优化器无法在 VARCHAR 的 B+ 树上定位 DATE_FORMAT(x)='...' 的入口
--   - type=ALL 全表扫描 20 万行，逐行计算 DATE_FORMAT 后再比较，性能极差
--   - 注意: 本案例与案例 04 互补。案例 04 讲 DATETIME 列上 DATE() 致索引失效，
--     本案例讲 VARCHAR 列上 DATE_FORMAT() 致索引失效——根源都是"函数包裹字段"，
--     但本案例重点是"格式选择错误(VARCHAR 存时间)逼出了 DATE_FORMAT 这种写法"。
EXPLAIN
SELECT '反模式2: DATE_FORMAT致索引失效' AS scenario,
       id, user_id, amount, created_at
FROM   t_time_bad
WHERE  DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01';

-- 实际查询
SELECT '反模式2: DATE_FORMAT致索引失效' AS scenario,
       id, user_id, amount, created_at
FROM   t_time_bad
WHERE  DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01'
ORDER BY created_at
LIMIT  10;

-- =====================================================================
-- 反模式 3: BETWEEN 字符串日期的边界陷阱（漏掉当天数据）
-- SELECT * FROM t_time_bad
-- WHERE created_at BETWEEN '2026-07-01' AND '2026-07-01';
-- 问题:
--   - BETWEEN 是闭区间 [start, end]，即 created_at >= '2026-07-01' AND created_at <= '2026-07-01'
--   - created_at 形如 '2026-07-01 08:00:00'，字典序 > '2026-07-01'（后面多了空格和时间）
--   - 因此 '2026-07-01 08:00:00' > '2026-07-01' 为真，但 <= '2026-07-01' 为假
--   - 结果: 当天 00:00:00 之后的所有数据全部漏掉，只能查到恰好等于 '2026-07-01' 的行（几乎没有）
--   - 这是字符串日期 BETWEEN 最经典的边界陷阱: 写的人以为 BETWEEN '7-1' AND '7-1' 是"查当天"，
--     实际只匹配字面量完全等于 '2026-07-01' 的行
SELECT '反模式3: BETWEEN边界陷阱' AS scenario,
       COUNT(*) AS cnt_0701_between
FROM   t_time_bad
WHERE  created_at BETWEEN '2026-07-01' AND '2026-07-01';
-- 预期 cnt_0701_between 极少(仅字面量恰好等于 '2026-07-01' 的行)，漏掉当天绝大部分数据!

-- 对比: 修正为带时间的 BETWEEN（仍是闭区间，但补齐时分秒到当天末尾）
SELECT '反模式3修正: BETWEEN补齐时分秒' AS scenario,
       COUNT(*) AS cnt_0701_between_fixed
FROM   t_time_bad
WHERE  created_at BETWEEN '2026-07-01 00:00:00' AND '2026-07-01 23:59:59';
-- 仍不完美: 23:59:59.999(若有小数秒)会漏掉; 且 BETWEEN 闭区间不如闭开区间优雅、不易错。
-- 正解见 good.sql: 用 DATETIME + 闭开区间 [start, end)。

-- =====================================================================
-- EXPLAIN 对比三个反模式的执行计划
-- =====================================================================
EXPLAIN SELECT id FROM t_time_bad WHERE created_at >= '2026-07-01' AND created_at < '2026-07-02';
EXPLAIN SELECT id FROM t_time_bad WHERE DATE_FORMAT(created_at, '%Y-%m-%d') = '2026-07-01';
EXPLAIN SELECT id FROM t_time_bad WHERE created_at BETWEEN '2026-07-01' AND '2026-07-01';
