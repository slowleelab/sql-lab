-- 分批删除：每次只删 1000 行，避免大事务
-- 生产中用脚本/程序循环执行此语句，直到 affected_rows = 0 停止：
--   while true:
--     execute "DELETE FROM t_log WHERE level=0 LIMIT 1000"
--     if affected_rows == 0: break
--     sleep 0.1s  -- 适当停顿，给主从同步留出窗口
DELETE FROM t_log WHERE level = 0 LIMIT 1000;
