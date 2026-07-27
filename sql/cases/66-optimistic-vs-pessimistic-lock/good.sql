-- good.sql: 乐观锁方式 - 原子条件更新，无需显式加锁
-- 利用 version 版本号做 CAS（Compare-And-Swap），冲突时 affected_rows=0 重试
--
-- 乐观锁流程：
--   1. SELECT stock, version FROM t_stock_lock WHERE product_id=1;  -- 无锁读（快照）
--   2. 应用层判断 stock > 0
--   3. UPDATE ... SET stock=stock-1, version=version+1
--        WHERE product_id=1 AND version=原版本 AND stock>0;          -- 原子 CAS
--   4. 若 affected_rows=0 表示版本已变（被其他事务改过），重试步骤1
--
-- 优势：不持有长锁，并发事务可并行读取，仅 UPDATE 瞬间加行锁

-- 步骤1: 无锁读取当前库存与版本（应用层保存 version 值）
SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1;

-- 步骤2: 乐观锁原子扣减（假设读到的 version=0，传入 WHERE version=0）
-- 若并发事务已修改，version 不匹配则 affected_rows=0，应用层重试
UPDATE t_stock_lock
SET stock = stock - 1,
    version = version + 1,
    updated_at = NOW()
WHERE product_id = 1
  AND version = 0
  AND stock > 0;
