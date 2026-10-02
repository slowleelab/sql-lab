-- good.sql: 改写为范围查询，等价于"当天"语义且不破坏索引
-- created_at >= '2026-07-01' AND created_at < '2026-07-02'
-- 列保持在原始形态，idx_created 可走 range 范围扫描
SELECT id, user_id, order_no, amount, created_at
FROM t_order_func
WHERE created_at >= '2026-07-01'
  AND created_at < '2026-07-02';
