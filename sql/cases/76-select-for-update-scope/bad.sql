-- bad.sql: WHERE 条件无索引，FOR UPDATE 锁升级为表锁
-- category 字段无索引，SELECT FOR UPDATE 无法走索引定位，退化为全表扫描加锁
-- 导致整张表所有行被锁，其他事务对该表任意行的更新/插入均被阻塞
--
-- 复现步骤（需两个会话）：
--
--   会话A（加锁）:
--     BEGIN;
--     SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;
--     -- category 无索引 -> 全表扫描 -> 锁定所有行（表锁效果）
--
--   会话B（被阻塞）:
--     BEGIN;
--     UPDATE t_product SET stock = stock - 1 WHERE id = 1;
--     -- ❌ 被阻塞！虽然 id=1 可能不是电子产品，但整表已被锁

BEGIN;

-- category 无索引，FOR UPDATE 锁全表（所有行加锁）
SELECT * FROM t_product WHERE category = '电子' FOR UPDATE;

-- 此时整表被锁，不 COMMIT，切换到会话B验证任意行更新被阻塞
