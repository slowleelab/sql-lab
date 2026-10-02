-- good.sql: 延迟关联 + 覆盖索引
--
-- 原理:
--   1. 子查询先通过覆盖索引 (idx_status_created) 快速定位到目标 20 条的 id
--      因为只查 id 和 status/created_at，可以走 "Using index" 不回表
--   2. 外层再通过主键 JOIN 回表取完整数据，只需 20 次回表
--
--   bad 方案要回表 2,000,020 次 (扫描+丢弃 200万 + 返回 20)
--   good 方案只回表 20 次
SELECT t.id, t.user_id, t.order_no, t.amount, t.status, t.created_at
FROM t_order t
INNER JOIN (
    SELECT id
    FROM t_order
    WHERE status = 1
    ORDER BY created_at DESC
    LIMIT 2000000, 20
) tmp ON t.id = tmp.id;
