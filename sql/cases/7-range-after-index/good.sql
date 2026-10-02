-- good.sql: 将 status 改为等值条件 status=2，amount 即可走索引
-- user_id(等值) -> status(等值) -> amount(范围) 三列都能用到联合索引
-- key_len 覆盖 user_id + status，amount 作为范围条件继续过滤
--
-- 说明: 若业务确需对 status 做范围查询(如 status>1)，
--       可调整联合索引列顺序，把范围列放到最后，例如改为
--       (user_id, amount, status)，使等值列在前、范围列在后，
--       最大化利用索引。索引列顺序应遵循"等值在前、范围在后"原则。
SELECT id, user_id, status, amount, created_at
FROM t_order_range
WHERE user_id = 1000
  AND status = 2
  AND amount > 500;
