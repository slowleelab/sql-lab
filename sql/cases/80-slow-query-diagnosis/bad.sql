-- bad.sql: 慢查询排查方法论 - 生产中发现的 3 条慢 SQL
--
-- 背景:
--   生产数据库 CPU 飙升到 90%，但不知道是哪条 SQL 导致的。
--   本文件演示完整的"发现 -> 定位 -> 验证"链路，重点不在单条 SQL 的优化，
--   而在"如何通过 slow log + pt-query-digest 发现这些慢 SQL"。
--
-- 诊断链路（DBA 优化的"第 0 步"：先找到该优化什么）:
--   slow log 采集 -> pt-query-digest 聚合指纹 -> performance_schema 定位 TOP SQL
--   -> EXPLAIN ANALYZE 验证 -> 逐条优化

-- ============================================================
-- 第 0 步: 开启 slow log 采集慢 SQL（本文件为注释，生产环境执行）
-- ============================================================
-- 查看当前慢查询日志配置
SHOW VARIABLES LIKE 'slow_query%';
SHOW VARIABLES LIKE 'long_query_time';
SHOW VARIABLES LIKE 'log_queries_not_using_indexes';

-- 运行时开启（重启失效）:
SET GLOBAL slow_query_log = 'ON';                       -- 开启慢查询日志
SET GLOBAL long_query_time = 1;                          -- 超过 1 秒记录（生产建议 0.1~1）
SET GLOBAL log_queries_not_using_indexes = 'ON';         -- 未走索引的查询也记录
SET GLOBAL min_examined_row_limit = 100;                 -- 扫描行数 < 100 不记录（降噪）

-- 8.0 推荐用 SET PERSIST 持久化（写入 mysqld-auto.cnf，重启保留）:
-- SET PERSIST slow_query_log = 'ON';
-- SET PERSIST long_query_time = 1;
-- SET PERSIST log_queries_not_using_indexes = 'ON';
-- 5.7 需手改 my.cnf 后重启:
--   [mysqld]
--   slow_query_log = 1
--   long_query_time = 1
--   log_queries_not_using_indexes = 1
--   slow_query_log_file = /var/log/mysql/slow.log

-- 查看慢日志文件路径
SHOW VARIABLES LIKE 'slow_query_log_file';

-- ============================================================
-- 第 1 步: pt-query-digest 聚合慢日志指纹（在 OS 上执行，非 SQL）
-- ============================================================
-- pt-query-digest 把数万条慢日志按"指纹"(把常量替换成 ?)聚合，
-- 输出每类 SQL 的总耗时、调用次数、平均耗时、样例，快速锁定 TOP N。
--
--   # 基础用法：分析慢日志，按总耗时排序
--   pt-query-digest /var/log/mysql/slow.log
--
--   # 只看排名前 10 的慢查询（精简输出）
--   pt-query-digest --order-by Query_time:sum --limit 10 /var/log/mysql/slow.log
--
--   # 按平均耗时排序（找单次最慢的）
--   pt-query-digest --order-by Query_time:avg --limit 10 /var/log/mysql/slow.log
--
-- 典型输出（节选）:
--   Rank  Query ID           Response time   Calls  R/Call    Apdx  Sample
--   ===== ================== =============== ====== ========= ====== =======
--   1     0xABC123...        1500.0000 45.0%   1500  1.0000    0.50  SELECT t_order_diag WHERE status=? ORDER BY created_at DESC LIMIT ?,?
--   2     0xDEF456...         900.0000 27.0%    900  1.0000    0.50  SELECT ... FROM t_order_diag WHERE user_id=? ORDER BY amount DESC
--   3     0xGHI789...         440.0000 13.0%    440  1.0000    0.50  SELECT COUNT(*) FROM t_order_diag WHERE DATE(created_at)=?
--   ----- ------------------ --------------- ------ --------- ------ -------
--   MISC  0x...               495.0000 15.0%   5000  0.0990    1.00  <8 ITEMS>
--
-- 结论: 排名前 3 的 SQL 占总耗时 85%，正是下面 3 条问题 SQL。
--       这就是 pt-query-digest 的价值——从海量日志里揪出"该优化什么"。

-- ============================================================
-- 第 2 步: 用 performance_schema 实时定位 TOP SQL（见 good.sql 文件头）
-- ============================================================
-- pt-query-digest 是"事后分析"慢日志；performance_schema 是"实时"统计。
-- performance_schema 的 TOP SQL 查询语句见 good.sql 文件开头注释。

-- ============================================================
-- 下面是 pt-query-digest 聚合出的 3 条 TOP 慢 SQL（按总耗时降序）
-- ============================================================

-- ------------------------------------------------------------
-- SQL 1（排名 #1，占总耗时 45%）: 深分页 + 无可用索引
-- 后台任务翻历史订单，翻到第 5001 页，OFFSET = 100000
-- 慢因:
--   WHERE status=1 无单独索引（idx_user 帮不上）-> 全表/全索引扫描
--   ORDER BY created_at 无索引有序性 -> filesort
--   LIMIT 100000, 20 深分页 -> 扫描并丢弃前 10 万行，每一行都付出代价
--   三者叠加：全表扫描 + filesort + 深分页回表
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE status = 1
ORDER BY created_at DESC
LIMIT 100000, 20;

-- ------------------------------------------------------------
-- SQL 2（排名 #2，占总耗时 27%）: 有 idx_user 但需回表 + filesort
-- 查某用户订单按金额倒序，user_id=12345 约 5 行
-- 慢因:
--   WHERE user_id=12345 能用 idx_user 定位（type=ref），看似没问题
--   但 ORDER BY amount DESC：idx_user 只有 user_id 一列，amount 无序
--   -> 必须把该 user 所有行回表读出 amount，再 filesort 排序
--   该用户行数少时还行；高并发下大量用户同时查，回表+filesort 累积成灾
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_diag
WHERE user_id = 12345
ORDER BY amount DESC;

-- ------------------------------------------------------------
-- SQL 3（排名 #3，占总耗时 13%）: 函数致索引失效
-- 统计某天订单量，用 DATE(created_at) = '某天'
-- 慢因:
--   created_at 上无单独索引（idx_user 是 user_id 的）
--   即使建了 idx_created，对列套函数 DATE(created_at) 也无法用索引
--   -> 全表扫描 50 万行逐行算 DATE() 再比较
--   这是"函数致索引失效"的典型，详见案例 04
SELECT COUNT(*) AS order_cnt
FROM t_order_diag
WHERE DATE(created_at) = '2026-07-01';
