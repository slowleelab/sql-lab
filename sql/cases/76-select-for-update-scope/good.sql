-- good.sql: 给 category 加索引后，FOR UPDATE 只锁匹配行（行锁）
-- 配合 setup-good.sql 执行 ALTER TABLE 添加 idx_category 索引
-- 索引定位后只对 category='电子' 的行加锁，其他分类的行不受影响
--
-- 复现步骤（先执行 setup-good.sql 加索引）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
--     -- 走 idx_category 索引 -> 只锁 category='电子' 的行
--
--   会话B（不被阻塞）:
--     BEGIN;
--     UPDATE t_product SET stock = stock - 1 WHERE id = 1;
--     -- ✅ 若 id=1 不是电子产品则不被阻塞（即使 update 电子行也仅等对应行锁）

BEGIN;

-- category 有索引，FOR UPDATE 只锁匹配的行
SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;

COMMIT;
