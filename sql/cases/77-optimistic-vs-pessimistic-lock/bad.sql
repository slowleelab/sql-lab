-- bad.sql: 悲观锁方式 - SELECT FOR UPDATE 锁行后更新
-- 整个事务期间持有行锁，其他事务必须等待，高并发下吞吐受限
--
-- 悲观锁流程：
--   1. BEGIN
--   2. SELECT stock FROM t_stock_lock WHERE product_id=1 FOR UPDATE;  -- 加行锁，读到 stock 值
--   3. 应用层判断 stock > 0
--   4. UPDATE t_stock_lock SET stock=stock-1 WHERE product_id=1;      -- 扣减
--   5. COMMIT  -- 释放行锁
--
-- 问题：步骤2~5期间行锁不释放，并发请求全部排队，吞吐量低

BEGIN;

-- 步骤1: 悲观锁查询，锁定 product_id=1 的行（持锁直到 COMMIT）
SELECT id, stock, version FROM t_stock_lock WHERE product_id = 1 FOR UPDATE;

-- 步骤2: 扣减库存（应用层在拿到 stock 值后判断 >0 再执行）
UPDATE t_stock_lock
SET stock = stock - 1, updated_at = NOW()
WHERE product_id = 1;

COMMIT;
