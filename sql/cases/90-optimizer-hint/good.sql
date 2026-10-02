-- good.sql: 使用 USE INDEX 强制使用 idx_user_created，避免 filesort
--
-- 优化原理：
--   1. USE INDEX (idx_user_created) 告诉优化器只考虑指定的索引
--   2. idx_user_created(user_id, created_at) 同时满足:
--      - WHERE user_id = 100: 索引第一列等值匹配
--      - ORDER BY created_at DESC: 索引第二列有序，直接利用索引顺序
--   3. 扫描 user_id=100 的约 10 行，索引有序直接取前 10 行，无需 filesort
--   4. 回表过滤 status=1，由于只有约 10 行，回表开销极小
--
-- 其他 Hint 用法:
--   FORCE INDEX (idx_user_created): 强制使用，比 USE INDEX 更强硬
--   IGNORE INDEX (idx_status): 禁止使用 idx_status，让优化器选其他索引
--
-- 使用场景:
--   - 优化器因统计信息不准确选错索引
--   - 数据分布变化导致执行计划退化
--   - 紧急修复线上慢查询（不改索引结构）

SELECT * FROM t_order USE INDEX (idx_user_created)
WHERE user_id = 100 AND status = 1
ORDER BY created_at DESC
LIMIT 10;
