-- bad.sql: 普通读取操作

-- 1. 普通 SELECT 从 Leader 读取（强一致读）
-- 如果有大量写入在进行中，Leader 负载高
SELECT COUNT(*) AS total_items, SUM(qty) AS total_qty, SUM(qty * price) AS total_value
FROM t_stale;

-- 2. 查看当前时间戳
SELECT NOW(), CURRENT_TIMESTAMP();

-- 3. 普通读取被写事务阻塞的场景
-- 在一个会话 BEGIN; UPDATE t_stale SET qty = qty + 1 WHERE id = 1;
-- 另一个会话 SELECT * FROM t_stale WHERE id = 1; -- 悲观模式下读锁等待

-- 4. 查看 tidb_read_staleness 设置
SHOW VARIABLES LIKE 'tidb_read_staleness';
