-- bad.sql: 一次性 UPDATE 50 万行，锁持有时间过长
--
-- 问题分析：
--   1. UPDATE t_order SET status = 3 WHERE status = 2 AND created_at < '2026-01-01'
--      匹配约 50 万行
--   2. 一次性更新 50 万行，InnoDB 需要:
--      - 锁定 50 万行（记录锁）
--      - 生成 50 万条 undo log
--      - 事务持续时间长（秒级甚至分钟级）
--   3. 危害:
--      - 锁持有时间过长，并发事务大量阻塞
--      - undo log 膨胀，MVCC 快照链过长
--      - 主从延迟加剧（从库回放同样耗时）
--      - 长事务导致 purge 线程无法清理 undo log
--
-- 实际执行时可能触发:
--   - ERROR 1205: Lock wait timeout exceeded（其他事务等待超时）
--   - 主从延迟报警
--   - 磁盘空间不足（undo log 膨胀）

UPDATE t_order
SET status = 3
WHERE status = 2
  AND created_at < '2026-01-01';
