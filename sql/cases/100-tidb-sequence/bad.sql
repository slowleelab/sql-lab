-- bad.sql: AUTO_INCREMENT 在 TiDB 中的局限
-- 分布式场景下不保证全局单调递增（可能有空洞/乱序）

-- 1. AUTO_INCREMENT 由 TiDB Server 层分配，每个 TiDB 实例缓存一段 ID
-- 多 TiDB 实例写入时，ID 跨实例不连续
INSERT INTO t_auto_inc (name, val) VALUES ('test1', 1), ('test2', 2), ('test3', 3);

SELECT '--- AUTO_INCREMENT ID 分布 ---' AS info;
SELECT * FROM t_auto_inc ORDER BY id;

-- 2. 查看 AUTO_INCREMENT 的锁模式
-- tidb_auto_increment_lock_mode=0 表示不使用锁，性能好但跨 TiDB 有空洞
-- tidb_auto_increment_lock_mode=1 表示使用锁保证连续性，但有性能开销
-- tidb_auto_increment_lock_mode=2 表示无锁且严格连续（Performance Schema 开销大）
SHOW VARIABLES LIKE 'tidb_auto_increment_lock_mode';

-- 3. AUTO_INCREMENT 空洞演示：事务回滚后 ID 被跳号
BEGIN;
INSERT INTO t_auto_inc (name, val) VALUES ('rollback_test', 999);
ROLLBACK;

-- 回滚后再次插入，ID 不连续
INSERT INTO t_auto_inc (name, val) VALUES ('after_rollback', 888);
SELECT id, name FROM t_auto_inc ORDER BY id DESC LIMIT 5;

-- 4. AUTO_INCREMENT 写入热点问题
-- 所有新 ID 递增落入同一个 Region，Leader 固定在一个 TiKV 节点
SHOW TABLE t_auto_inc REGIONS;

-- 对比：AUTO_RANDOM 的 Region 分布（写入打散到多个 Region）
SHOW TABLE t_auto_rand REGIONS;
