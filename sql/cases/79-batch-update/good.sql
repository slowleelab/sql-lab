-- good.sql: 分批更新，每次 1000 行，减少锁持有时间
--
-- 优化原理：
--   1. 每次 UPDATE 只更新 1000 行，锁持有时间从分钟级降到毫秒级
--   2. 分批提交，undo log 及时 purge，不会膨胀
--   3. 主从延迟可控（每批在从库回放快）
--   4. 并发事务几乎不会感知到锁等待
--
-- 执行方式:
--   重复执行以下 SQL，直到 affected_rows = 0
--   可在应用层循环执行，或存储过程中循环
--
-- 注意事项:
--   - LIMIT 1000 是经验值，可根据业务调整（通常 500~5000）
--   - 每批之间可加入短暂休眠（如 10ms），进一步降低对线上业务的影响
--   - 需确保 WHERE 条件能利用索引，避免每批都全表扫描

-- 分批更新，每次 1000 行
UPDATE t_order
SET status = 3
WHERE status = 2
  AND created_at < '2026-01-01'
LIMIT 1000;

-- 重复执行直到 affected_rows = 0
-- 应用层伪代码:
--   do {
--       affected = execute("UPDATE ... LIMIT 1000");
--       sleep(10);  // 可选：短暂休眠
--   } while (affected > 0);
