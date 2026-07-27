-- good.sql: FOR UPDATE NOWAIT 和 SKIP LOCKED——避免锁等待阻塞

-- ============================================
-- 方式一: FOR UPDATE NOWAIT——获取不到锁立即报错
-- ============================================

-- 会话A: 先持有 id=1 的锁
-- BEGIN;
-- SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE;

-- 会话B: 尝试获取同一行的锁——立即返回错误，不等待
BEGIN;
SELECT * FROM t_lock_test WHERE id = 1 FOR UPDATE NOWAIT;
-- 如果 id=1 已被锁定，立即返回：
-- ERROR 3572 (HY000): Statement aborted because lock(s) could not be acquired
--                     immediately and NOWAIT is set.
ROLLBACK;

-- ============================================
-- 方式二: FOR UPDATE SKIP LOCKED——跳过已锁定的行
-- ============================================

-- 会话A: 先持有 id=1 和 id=2 的锁
-- BEGIN;
-- SELECT * FROM t_lock_test WHERE id IN (1, 2) FOR UPDATE;

-- 会话B: SKIP LOCKED 跳过已锁定的行，只返回未锁定的行
BEGIN;
SELECT * FROM t_lock_test FOR UPDATE SKIP LOCKED;
-- 返回 id=3,4,5 的行（id=1,2 已被会话A锁定，被跳过）
-- 会话B 对这些行加了行锁，可以安全处理
ROLLBACK;

-- ============================================
-- 锁排查工具：LOCK VIEW 和 DATA_LOCK_WAITS
-- ============================================

-- 查看当前锁等待关系（需要在锁等待发生时执行）：
SELECT
    requesting_trx_id,
    blocking_trx_id,
    wait_key,
    wait_start_time
FROM information_schema.data_lock_waits;

-- 查看死锁历史（排查死锁问题）：
SELECT * FROM information_schema.deadlocks;

-- 查看锁视图（TiDB 独有，类似 MySQL DATA_LOCKS）：
-- TiDB 通过 CLUSTER_PROCESSLIST 和 DATA_LOCK_WAITS 组合排查锁等待链

-- ============================================
-- SKIP LOCKED 典型应用：库存扣减（秒杀场景）
-- ============================================

-- 示例：对一个商品的多个库存批次（id=1~5 代表5个批次）进行扣减
-- 多个并发请求各自获取一个未锁定的批次进行扣减，互不阻塞
BEGIN;
SELECT * FROM t_lock_test WHERE qty > 0
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;
-- 获取到一个未被其他事务锁定的库存行
-- 在应用层判断 qty > 0 后执行扣减
UPDATE t_lock_test SET qty = qty - 1 WHERE id = ? AND qty > 0;
COMMIT;

-- 对比说明：
-- | 方式                  | 锁竞争行为       | 适用场景         |
-- |-----------------------|------------------|------------------|
-- | FOR UPDATE            | 阻塞等待         | 必须等待锁       |
-- | FOR UPDATE NOWAIT     | 立即返回错误     | 快速失败重试     |
-- | FOR UPDATE SKIP LOCKED| 跳过已锁行       | 队列消费、库存扣减 |
