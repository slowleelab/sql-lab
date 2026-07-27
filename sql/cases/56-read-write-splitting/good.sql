-- good.sql: 读查询路由到从库，主库专注写入，读写互不干扰
-- 从库横向扩展可线性提升读吞吐，主库写入性能不受读流量影响
-- 注意: 对强一致读（如刚下单立即查询）仍应读主库，避免复制延迟读到旧数据
SELECT *
FROM t_order_replica
WHERE user_id = 12345
ORDER BY created_at DESC
LIMIT 20;
