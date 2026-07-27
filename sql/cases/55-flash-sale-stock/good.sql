-- 原子条件更新（乐观锁）：WHERE stock > 0 防超卖
-- 单条 UPDATE 利用 InnoDB 行锁保证原子性：判断 stock>0 和扣减在同一事务内完成
-- 返回 affected_rows=1 表示扣减成功，=0 表示库存不足（已被抢完）
-- version+1 用于乐观锁冲突检测（可选，stock>0 已足够防超卖）
UPDATE t_stock
SET stock = stock - 1,
    version = version + 1,
    updated_at = NOW()
WHERE product_id = 1 AND stock > 0;
