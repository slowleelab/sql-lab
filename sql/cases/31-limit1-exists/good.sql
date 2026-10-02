-- good.sql: 用 EXISTS + LIMIT 1 检查用户是否有未支付订单
-- EXISTS 子查询找到第一行匹配记录就立即返回 TRUE，无需扫描全部匹配行。
-- LIMIT 1 进一步明确"只要一行"的意图，帮助优化器选择最短执行路径。
-- 对于"是否存在"的判断，EXISTS 的短路特性比 COUNT(*) 高效得多。
SELECT *
FROM t_user_exists u
WHERE EXISTS (SELECT 1
              FROM t_order_exists o
              WHERE o.user_id = u.id
                AND o.status = 0
              LIMIT 1);
