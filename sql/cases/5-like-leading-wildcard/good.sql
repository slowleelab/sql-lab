-- good.sql: LIKE 使用后导通配符 'zhang%'
-- 只有尾部 %，B+ 树可定位到 'zhang' 前缀起点向后范围扫描，idx_username 走 range
-- 注意: 仅匹配以 zhang 开头的用户名，语义与 '%zhang%' 不同
--       若业务确需包含匹配，应考虑全文索引(FULLTEXT)或外部搜索引擎
SELECT id, username, nickname, phone, created_at
FROM t_user_search
WHERE username LIKE 'zhang%';
