-- 先查后改模式（非原子，并发下超卖）：
-- 步骤1: SELECT 查库存 -> 应用层判断 stock > 0
-- 步骤2: UPDATE SET stock=stock-1
-- 两个步骤之间存在时间窗口，并发请求都读到 stock>0 则都执行扣减 -> 超卖
-- bad.sql 展示步骤1的 SELECT（问题根源在查询与更新的非原子性）
SELECT stock FROM t_stock WHERE product_id = 1;
